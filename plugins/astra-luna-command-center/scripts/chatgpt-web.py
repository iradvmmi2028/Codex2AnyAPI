#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""chatgpt-web.py -- ChatGPT Web 自动化 transport for astra-luna-command-center.

复刻 codex-chatgpt-web 的浏览器桥思路的"零风险最小子集"：不读改 ChatGPT 页面
内部状态、不注入脚本、不接 MCP。浏览器优先使用本机默认浏览器（QQ 浏览器，
其次 Edge/Chrome），分两条路径：

* CDP 接管（send/status 优先）：默认浏览器若已带 --remote-debugging-port 运行，
  直接连该实例（复用你已登录的会话），在现有页面里发一条消息并读回复。
  不改 cookie、不开新窗口、不关浏览器。
* playwright 持久化 profile（login 与回退路径）：用默认浏览器程序 + 独立
  profile 目录，人工登录一次后复用登录态。

命令：
  doctor -- 环境探测（python/playwright/浏览器/脚本/profile；不开浏览器）
  login  -- 打开浏览器（默认 QQ），人工登录；登录态持久化到 profile 目录
  status -- 探测登录态与当前模型（优先接管运行中的浏览器）
  send   -- 发 payload 等回复，结果写 result 文件（优先接管运行中的浏览器）

退出码（与 astra-luna.ps1/.sh 诊断文案一致）：
  0 成功；2 环境缺失；3 未登录；4 提交失败；5 生成超时；6 提取失败

安全与边界：
* 只在本机、当前用户自己的 ChatGPT 账号上使用；遵守 OpenAI 服务条款。
* CDP 只接 127.0.0.1（远程调试端口不得暴露到局域网）。
* 会话内容是敏感输入：只写落到上层指定的 profile/result 路径，不碰剪贴板。
* ChatGPT 页面随时会改版：选择器失效时 exit 4/5/6 显式报错，绝不静默降级。
* 浏览器里选中的模型由用户负责（应选 GPT-5.6 Luna，effort max），send 后回报实际模型。
* 所有 stdout 输出都是 JSON（上层解析用）；人类可读日志一律走 stderr。
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

EXIT_OK = 0
EXIT_ENV = 2
EXIT_NOT_LOGGED_IN = 3
EXIT_SUBMIT = 4
EXIT_TIMEOUT = 5
EXIT_EXTRACT = 6

CHATGPT_HOME = "https://chatgpt.com/"

# 页面选择器（对照 codex-chatgpt-web 的 chatgpt-session.ts / bridge.ts，
# ChatGPT 实际 DOM：prompt 输入区带 data-testid="prompt-textarea"）。
COMPOSER_SELECTORS = [
    'textarea[data-testid="prompt-textarea"]',
    'div[data-testid="prompt-textarea"]',
    'textarea#prompt-textarea',
    'div#prompt-textarea',
    '[contenteditable="true"]',
]
NEW_CHAT_SELECTORS = [
    '[data-testid="new-chat-button"]',
    'button[aria-label*="new chat" i], a[aria-label*="new chat" i]',
    'button[data-testid="chat-input-new-chat"]',
]
STOP_SELECTOR = '[data-testid="stop-button"]'
ASSISTANT_TURN_SELECTORS = [
    '[data-message-author-role="assistant"]',
    '[data-testid^="conversation-turn-"][data-turn="assistant"]',
    '[data-testid^="conversation-turn-"]:has([data-message-author-role="assistant"])',
]
MODEL_SELECTORS = [
    '[data-testid="model-switcher-dropdown-text"]',
    '[data-testid="model-switcher-dropdown-button"]',
]

PROFILE_ENV = "ASTRA_LUNA_CHATGPT_PROFILE"
BROWSER_ENV = "ASTRA_LUNA_CHATGPT_BROWSER"
SCRIPT_ENV = "ASTRA_LUNA_CHATGPT_BIN"
CDP_PORT_ENV = "ASTRA_LUNA_CHATGPT_CDP_PORT"

# 提交后确认已发送的窗口（stop 出现 / 输入框清空）
SUBMIT_CONFIRM_SECONDS = 60
# stop 消失后、提取 assistant turn 前的额外缓冲（渲染/流式收尾）
EXTRACT_GRACE_SECONDS = 90
# 回应还在继续生成时（composer 文本未清空 / 模型无输出），放宽到全量 timeout。
# 原本在 stop 消失后立即提取：页面持续流式输出时 stop 会短暂消失,
# 停在半腰上的结果会被误当成"最终回复",从而出现（截断/停止）后的中断。
# 现在只要回复仍在流式增长就继续等，直到 timeout 或结果稳定 90 s。
EXTRACT_MAX_SECONDS = 1800

# 生成结束时再等一小段,确认真的算完成（没有再续写、没有立刻重新开始）。
FINISH_SETTLE_SECONDS = 15

_WS_RE = re.compile(r"\s+")


def log(msg):
    print("chatgpt-web: " + msg, file=sys.stderr)


def this_script():
    return str(Path(__file__).resolve())


def die(code, msg):
    log(msg)
    sys.exit(code)


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False))


# ------------------------------------------------------------------ 环境探测

def _browser_candidates():
    pf_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    pf = os.environ.get("ProgramFiles", r"C:\Program Files")
    local = os.environ.get("LOCALAPPDATA", "")
    out = []
    for root in (pf, pf_x86, local):
        out.append(Path(root) / "Tencent" / "QQBrowser" / "QQBrowser.exe")
    for root in (pf_x86, pf, local):
        out.append(Path(root) / "Microsoft" / "Edge" / "Application" / "msedge.exe")
    out.append(Path(pf) / "Google" / "Chrome" / "Application" / "chrome.exe")
    return out


def find_browser():
    """默认浏览器优先：QQ 浏览器 > Edge > Chrome。找不到返回 ''。"""
    explicit = os.environ.get(BROWSER_ENV, "").strip()
    if explicit:
        return explicit if Path(explicit).is_file() else ""
    for c in _browser_candidates():
        if c.is_file():
            return str(c)
    return ""


def qqbrowser_profile_dir():
    """默认 QQ 浏览器 User Data 目录（用于 doctor 报告）。"""
    local = os.environ.get("LOCALAPPDATA", "")
    if local:
        return str(Path(local) / "Tencent" / "QQBrowser" / "User Data")
    return ""


def default_profile():
    st = os.environ.get("ASTRA_LUNA_STATE_DIR", "").strip()
    base = st if st else str(Path.home() / ".astra-luna")
    return str(Path(base) / "chatgpt-web-profile")


def playwright_ok():
    try:
        import playwright  # noqa: F401
        return True
    except ImportError:
        return False


# ------------------------------------------------------------------ playwright

def browser_surface(profile_dir, headless=False):
    """用 playwright 持久化 profile 启动默认浏览器，返回 (ctx, page)。

    失败抛 RuntimeError，由调用方转成 exit 2。"""
    if not playwright_ok():
        raise RuntimeError("缺少 Python 模块 playwright（安装: python -m pip install playwright）")
    from playwright.sync_api import sync_playwright
    exe = find_browser()
    pw = sync_playwright().start()
    try:
        ctx = pw.chromium.launch_persistent_context(
            user_data_dir=profile_dir,
            headless=headless,
            executable_path=exe or None,
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-first-run",
                "--no-default-browser-check",
                "--restore-last-session",
            ],
        )
    except Exception as e:
        raise RuntimeError("无法启动浏览器（%s）。若该浏览器正以同一 profile 运行，先关闭重试。" % e)
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    return ctx, page


def _visible(page, selector, timeout_ms=1200):
    try:
        return page.locator(selector).first.is_visible(timeout=timeout_ms)
    except Exception:
        return False


def new_chat(page):
    for sel in NEW_CHAT_SELECTORS:
        try:
            if page.locator(sel).first.is_visible(timeout=1200):
                page.locator(sel).first.click(timeout=2000)
                return True
        except Exception:
            continue
    return False


def current_model(page):
    for sel in MODEL_SELECTORS:
        try:
            el = page.locator(sel).first
            if el.is_visible(timeout=1200):
                t = el.inner_text().strip()
                if t:
                    return re.sub(r"\s+", " ", t)[:200]
        except Exception:
            continue
    return ""


def wait_composer(page, timeout_s):
    deadline = time.time() + timeout_s
    last_err = None
    while time.time() < deadline:
        for sel in COMPOSER_SELECTORS:
            try:
                el = page.locator(sel).last
                if el.is_visible(timeout=800):
                    return el
            except Exception as e:
                last_err = e
        time.sleep(0.25)
    raise RuntimeError(
        "等待 composer 超时（%d s%s）" % (
            timeout_s, "；最近错误: %s" % last_err if last_err else ""))


def require_logged_in(page, timeout_s):
    try:
        return wait_composer(page, timeout_s)
    except RuntimeError as e:
        url = ""
        try:
            url = page.url
        except Exception:
            pass
        raise RuntimeError(
            "未检测到已登录的 ChatGPT 页面（URL=%s；%s）；"
            "先运行: python chatgpt-web.py login" % (url, e))


def assistant_last_text(page):
    """最后一条文本非空的 assistant turn；没有则返回 ''。"""
    loc = page.locator(", ".join(ASSISTANT_TURN_SELECTORS))
    n = loc.count()
    for i in range(n - 1, -1, -1):
        try:
            t = loc.nth(i).inner_text()
        except Exception:
            continue
        t = _WS_RE.sub(" ", t).strip() if t else ""
        if t:
            return t
    return ""


# ------------------------------------------------------------------ CDP

class CdpSession:
    """连接到已在运行的浏览器（--remote-debugging-port）。"""

    def __init__(self, target, ws, version):
        self.target = target
        self.ws = ws
        self.version = version or {}
        self._seq = 0

    def eval(self, expression, timeout_s=20):
        """在接管页面执行 JS，返回 byValue 结果；出错抛 RuntimeError。"""
        self._seq += 1
        msg = json.dumps({
            "id": self._seq,
            "method": "Runtime.evaluate",
            "params": {"expression": expression, "returnByValue": True,
                       "awaitPromise": True},
        })
        self.ws.send(msg)
        while True:
            resp = json.loads(self.ws.recv())
            if resp.get("id") != self._seq:
                continue
            if "error" in resp:
                raise RuntimeError("CDP: %s" % resp["error"].get("message", resp["error"]))
            r = resp["result"]
            if "exceptionDetails" in r:
                raise RuntimeError("页面执行失败: %s" %
                                   r["exceptionDetails"].get("text", ""))
            return (r.get("result") or {}).get("value")

    def press_enter(self):
        """发一个真实键盘回车（keyDown+keyUp）。"""
        for event in ("keyDown", "keyUp"):
            self._seq += 1
            self.ws.send(json.dumps({
                "id": self._seq,
                "method": "Input.dispatchKeyEvent",
                "params": {
                    "type": event, "modifiers": 0, "key": "Enter",
                    "code": "Enter", "windowsVirtualKeyCode": 13,
                    "nativeVirtualKeyCode": 13,
                },
            }))
            json.loads(self.ws.recv())

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


def cdp_connect(port=9222, timeout_s=8):
    """连接 127.0.0.1:port 的浏览器调试接口；失败抛 RuntimeError。"""
    import requests as _req
    try:
        ver = _req.get("http://127.0.0.1:%d/json/version" % port, timeout=timeout_s)
        ver.raise_for_status()
        version = ver.json()
        pages = _req.get("http://127.0.0.1:%d/json/list" % port, timeout=timeout_s)
        pages.raise_for_status()
    except Exception as e:
        raise RuntimeError("CDP 不可达（端口 %d）: %s" % (port, e))
    targets = [t for t in pages.json() if t.get("type") == "page"]
    if not targets:
        raise RuntimeError("CDP 无可用页面")
    # 优先 chatgpt.com 标签页，否则第一个普通页面
    t = next((x for x in targets if "chatgpt.com" in (x.get("url") or "")), targets[0])
    try:
        import websocket
        ws = websocket.create_connection(t["webSocketDebuggerUrl"], timeout=timeout_s)
    except Exception as e:
        raise RuntimeError("CDP WebSocket 连接失败: %s" % e)
    return CdpSession(t, ws, version)


def cdp_navigate_to_chatgpt(cdp):
    """接管页面不在 chatgpt.com 时导航过去（沿用当前 tab）。"""
    try:
        url = cdp.target.get("url") or ""
    except Exception:
        url = ""
    if "chatgpt.com" not in url:
        cdp.eval("location.href=%s" % json.dumps(CHATGPT_HOME))
        time.sleep(2)


def _composer_js(sel):
    return (
        "(()=>{const el=document.querySelector(%s);"
        "if(!el)return {found:false};"
        "return {found:true,is_textarea:el.tagName==='TEXTAREA',"
        "is_editable:el.isContentEditable||el.getAttribute('contenteditable')==='true'}})()"
        % json.dumps(sel))


def cdp_wait_composer(cdp, timeout_s=30):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        for sel in COMPOSER_SELECTORS:
            try:
                r = cdp.eval(_composer_js(sel))
                if r and r.get("found"):
                    return sel, r
            except Exception:
                pass
        time.sleep(0.3)
    return None, None


def cdp_fill(cdp, sel, info, payload):
    """在 composer 里填入 payload。textarea 用原生 value setter（触发 React
    onChange）；contenteditable 用 execCommand('insertText')。"""
    if info and info.get("is_textarea"):
        js = (
            "(()=>{const el=document.querySelector(%s);el.focus();"
            "const d=Object.getOwnPropertyDescriptor(el.__proto__,'value');"
            "const set=d?d.set:Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set;"
            "set.call(el,%s);"
            "el.dispatchEvent(new Event('input',{bubbles:true}));"
            "el.dispatchEvent(new Event('change',{bubbles:true}));return true})()"
            % (json.dumps(sel), json.dumps(payload)))
    else:
        js = (
            "(()=>{const el=document.querySelector(%s);el.focus();"
            "const ok=document.execCommand('insertText',false,%s);"
            "if(!ok){el.textContent=%s;"
            "el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:%s}));}"
            "return true})()"
            % (json.dumps(sel), json.dumps(payload), json.dumps(payload), json.dumps(payload)))
    cdp.eval(js)
    time.sleep(0.5)


def cdp_last_assistant_text(cdp):
    js = (
        "(()=>{const els=document.querySelectorAll(%s);"
        "for(let i=els.length-1;i>=0;i--){const t=(els[i].innerText||'').trim();"
        "if(t)return t}return ''})()"
        % json.dumps(", ".join(ASSISTANT_TURN_SELECTORS)))
    return cdp.eval(js)


def is_streaming(cdp, sel):
    """仍在生成中?的粗略判据：stop 按钮存在，或 composer 里还有未清空的文本。
    无法判断时返回 False（宁可早收也不重等）。
    GPT-5 长输出时 stop 会在输出流之间短暂消失,但 composer 未清空就说明还没完。"""
    try:
        if cdp.eval("!!document.querySelector(%s)" % json.dumps(STOP_SELECTOR)):
            return True
    except RuntimeError:
        pass
    try:
        return bool(cdp.eval(
            "(()=>{const el=document.querySelector(%s);"
            "return el?!!(el.tagName==='TEXTAREA'?(el.value||''):(el.innerText||'')).trim():false})()"
            % json.dumps(sel)))
    except RuntimeError:
        return False


def cdp_send_flow(cdp, payload, timeout_s, result_file):
    """在接管页面执行：等 composer -> 新对话 -> 填入 -> 回车 -> 等回复 -> 写文件。

    返回 (exit_code, 说明/文本)。"""
    cdp_navigate_to_chatgpt(cdp)
    # 1. 等 composer（登录态校验）
    sel, info = cdp_wait_composer(cdp, timeout_s=60)
    if not sel:
        return EXIT_NOT_LOGGED_IN, "未检测到已登录的 ChatGPT 页面（CDP）"
    # 2. 新对话
    for s in NEW_CHAT_SELECTORS:
        try:
            cdp.eval("(()=>{const el=document.querySelector(%s);if(el&&el.offsetParent)el.click()})()"
                     % json.dumps(s))
        except Exception:
            pass
    time.sleep(1.0)
    sel, info = cdp_wait_composer(cdp, timeout_s=10)
    if not sel:
        return EXIT_NOT_LOGGED_IN, "新对话后 composer 消失"
    # 3. 填入
    try:
        cdp_fill(cdp, sel, info, payload)
    except RuntimeError as e:
        return EXIT_SUBMIT, "composer 无法填入 payload: %s" % e
    # 4. 回车
    try:
        cdp.press_enter()
    except RuntimeError as e:
        return EXIT_SUBMIT, "composer 无法发送: %s" % e
    # 5. 等已发送（stop 出现 / 输入框清空）
    deadline = time.time() + SUBMIT_CONFIRM_SECONDS
    while True:
        if time.time() > deadline:
            return EXIT_SUBMIT, "提交失败：%d s 内未检测到已发送" % SUBMIT_CONFIRM_SECONDS
        try:
            if cdp.eval("!!document.querySelector(%s)" % json.dumps(STOP_SELECTOR)):
                break
            cleared = cdp.eval(
                "(()=>{const el=document.querySelector(%s);"
                "return el?!(el.tagName==='TEXTAREA'?(el.value||''):(el.innerText||'')).trim():true})()"
                % json.dumps(sel))
            if cleared:
                break
        except RuntimeError:
            pass
        time.sleep(0.5)
    # 6. 等流式回复真正结束：stop 消失 + 输入框清空 + 持续 FINISH_SETTLE_SECONDS。
    #    上限 EXTRACT_MAX_SECONDS（不再受上层 wall-clock timeout 卡脖子）。
    deadline = time.time() + EXTRACT_MAX_SECONDS
    settled = 0.0
    while time.time() < deadline:
        streaming = is_streaming(cdp, sel)
        if not streaming:
            settled += 0.5
            if settled >= FINISH_SETTLE_SECONDS:
                break
            time.sleep(0.5)
            continue
        settled = 0.0
        time.sleep(0.5)
    if time.time() > deadline:
        return EXIT_TIMEOUT, "流式生成在 %d s 内未完结（持续输出）" % EXTRACT_MAX_SECONDS
    # 7. 提取最后一条 assistant turn
    last = ""
    deadline = time.time() + EXTRACT_GRACE_SECONDS
    while time.time() < deadline:
        try:
            last = cdp_last_assistant_text(cdp)
        except RuntimeError:
            last = ""
        if last:
            break
        time.sleep(1)
    if not last:
        return EXIT_EXTRACT, "提取失败：没有找到文本非空的 assistant turn"
    Path(result_file).write_text(last + "\n", encoding="utf-8", newline="")
    return EXIT_OK, last


def cdp_navigate_to_chatgpt(cdp):
    """接管页面不在 chatgpt.com 时导航过去（沿用当前 tab）。"""
    try:
        url = cdp.target.get("url") or ""
    except Exception:
        url = ""
    if "chatgpt.com" not in url:
        cdp.eval("location.href=%s" % json.dumps(CHATGPT_HOME))
        time.sleep(2)


def cdp_status(cdp):
    """接管已有浏览器，探测 chatgpt.com 登录态与当前模型。返回 (logged_in, model)。"""
    cdp_navigate_to_chatgpt(cdp)
    sel, _ = cdp_wait_composer(cdp, timeout_s=60)
    if not sel:
        return False, ""
    model = ""
    for selm in MODEL_SELECTORS:
        try:
            m = cdp.eval(
                "(()=>{const el=document.querySelector(%s);"
                "return el?(el.innerText||'').trim().slice(0,200):''})()"
                % json.dumps(selm))
            if m:
                model = re.sub(r"\s+", " ", m)
                break
        except Exception:
            continue
    return True, model


# ------------------------------------------------------------------ 命令

def cmd_doctor(args, cdp=None):
    facts = {
        "ok": True,
        "script": this_script(),
        "python": sys.executable,
        "playwright": playwright_ok(),
        "browser": bool(find_browser()),
        "browser_path": find_browser() or "",
        "qqbrowser_userdata": qqbrowser_profile_dir(),
        "qqbrowser_userdata_exists": bool(qqbrowser_profile_dir()) and Path(qqbrowser_profile_dir()).exists(),
        "profile": args.profile,
        "profile_exists": Path(args.profile).exists(),
        "cdp_port": args.cdp_port,
    }
    emit(facts)
    return EXIT_OK


def cmd_login(args, cdp=None):
    ctx = None
    try:
        ctx, page = browser_surface(args.profile, headless=False)
        page.goto(CHATGPT_HOME, wait_until="domcontentloaded", timeout=args.timeout * 1000)
        log("已打开浏览器窗口（%s）。若该浏览器已在 QQ 浏览器主窗口登录，此窗口会直接通过；"
            "否则请在窗口内登录 ChatGPT（登录态保存在 profile 目录，后续复用）。"
            % (find_browser() or "默认浏览器"))
        wait_composer(page, args.timeout)
        model = current_model(page)
        emit({"ok": True, "logged_in": True, "model": model, "profile": args.profile,
              "source": "profile"})
        return EXIT_OK
    except RuntimeError as e:
        log("login: 不成功（%s）。profile 已保留，可重试或改用 --timeout 加大等待。" % e)
        if "未检测到已登录" in str(e) or "等待 composer 超时" in str(e):
            return EXIT_NOT_LOGGED_IN
        return EXIT_ENV
    finally:
        if ctx:
            try:
                ctx.close()
            except Exception:
                pass


def cmd_status(args, cdp=None):
    if cdp is not None:
        try:
            ok, model = cdp_status(cdp)
            emit({"ok": ok, "logged_in": ok, "model": model, "source": "cdp"})
            return EXIT_OK if ok else EXIT_NOT_LOGGED_IN
        except Exception as e:
            log("status(cdp) 失败，回退 profile: %s" % e)
    ctx = None
    try:
        ctx, page = browser_surface(args.profile, headless=False)
        page.goto(CHATGPT_HOME, wait_until="domcontentloaded", timeout=args.timeout * 1000)
        require_logged_in(page, 60)
        model = current_model(page)
        emit({"ok": True, "logged_in": True, "model": model, "source": "profile"})
        return EXIT_OK
    except RuntimeError as e:
        if "未检测到已登录" in str(e):
            emit({"ok": False, "logged_in": False, "model": "", "source": "profile"})
            return EXIT_NOT_LOGGED_IN
        log(str(e))
        return EXIT_ENV
    finally:
        if ctx:
            try:
                ctx.close()
            except Exception:
                pass


def cmd_send(args, cdp=None):
    payload = Path(args.payload_file)
    if not payload.is_file():
        die(EXIT_ENV, "payload 文件不存在：%s" % payload)
    data = payload.read_text(encoding="utf-8")
    if not data.strip():
        die(EXIT_ENV, "payload 文件为空：%s" % payload)

    # 优先 CDP 接管（用户默认浏览器已在跑且带调试端口）
    if cdp is not None:
        rc, msg = cdp_send_flow(cdp, data, args.timeout, str(args.result_file))
        if rc != EXIT_OK:
            die(rc, msg)
        Path(args.result_file).write_text(msg + "\n", encoding="utf-8", newline="")
        emit({"ok": True, "result_file": str(args.result_file),
              "bytes": len((msg + "\n").encode("utf-8")), "source": "cdp"})
        return EXIT_OK

    # 回退：playwright 持久化 profile
    ctx = None
    try:
        ctx, page = browser_surface(args.profile, headless=False)
        page.goto(CHATGPT_HOME, wait_until="domcontentloaded", timeout=args.timeout * 1000)
        composer = require_logged_in(page, 60)
        new_chat(page)
        try:
            composer = require_logged_in(page, 30)
        except RuntimeError:
            pass
        try:
            composer.click()
            composer.fill(data)
        except Exception:
            try:
                page.keyboard.insert_text(data)
            except Exception as e:
                raise RuntimeError("composer 无法填入 payload: %s" % e)
        page.keyboard.press("Enter")
        submitted = False
        deadline = time.time() + SUBMIT_CONFIRM_SECONDS
        while time.time() < deadline:
            try:
                if page.locator(STOP_SELECTOR).count() > 0:
                    submitted = True
                    break
                t = composer.evaluate("el => el.tagName === 'TEXTAREA' ? el.value : el.innerText")
                if isinstance(t, str) and not t.strip():
                    submitted = True
                    break
            except Exception:
                pass
            time.sleep(0.3)
        if not submitted:
            die(EXIT_SUBMIT, "提交失败：%d s 内未检测到已发送" % SUBMIT_CONFIRM_SECONDS)
        deadline = time.time() + args.timeout
        stop_seen = False
        while time.time() < deadline:
            try:
                if page.locator(STOP_SELECTOR).count() > 0:
                    stop_seen = True
                    break
            except Exception:
                pass
            time.sleep(0.5)
        if stop_seen:
            while page.locator(STOP_SELECTOR).count() > 0 and time.time() < deadline:
                time.sleep(0.5)
            if page.locator(STOP_SELECTOR).count() > 0:
                die(EXIT_TIMEOUT, "生成超时：stop 按钮在 %d s 内未消失" % args.timeout)
        last = ""
        extract_deadline = time.time() + EXTRACT_GRACE_SECONDS
        while time.time() < extract_deadline:
            last = assistant_last_text(page)
            if last:
                break
            time.sleep(1)
        if not last:
            die(EXIT_EXTRACT, "提取失败：没有找到文本非空的 assistant turn")
        Path(args.result_file).write_text(last + "\n", encoding="utf-8", newline="")
        model = current_model(page)
        emit({"ok": True, "result_file": args.result_file,
              "bytes": len((last + "\n").encode("utf-8")), "model": model, "source": "profile"})
        return EXIT_OK
    except RuntimeError as e:
        if "未检测到已登录" in str(e):
            die(EXIT_NOT_LOGGED_IN, str(e))
        die(EXIT_ENV, "运行失败: %s" % e)
    finally:
        if ctx:
            try:
                ctx.close()
            except Exception:
                pass
    return EXIT_OK


# ------------------------------------------------------------------ cli

def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="chatgpt-web.py",
        description="ChatGPT Web transport for astra-luna command center")
    p.add_argument("--timeout", type=int, default=900, help="等待超时（秒）")
    p.add_argument("--browser", default=None, help="浏览器可执行文件路径（默认自动找 QQ/Edge/Chrome）")
    p.add_argument("--profile", default="",
                   help="持久化 profile 目录（默认 state_dir/chatgpt-web-profile 或 ~/.astra-luna/chatgpt-web-profile）")
    p.add_argument("--cdp-port", type=int, default=int(os.environ.get(CDP_PORT_ENV, "9222")),
                   help="已运行浏览器的调试端口（默认 9222）")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="环境探测（不开浏览器）").set_defaults(fn=cmd_doctor)
    sub.add_parser("login", help="浏览器人工登录，持久化 profile").set_defaults(fn=cmd_login)
    sub.add_parser("status", help="只读：登录态 + 当前模型").set_defaults(fn=cmd_status)
    s = sub.add_parser("send", help="发送 payload 文本、等待回复，结果写 result 文件")
    s.add_argument("--payload-file", required=True, help="执行包 payload 文件路径")
    s.add_argument("--result-file", required=True, help="结果写入的路径")
    s.add_argument("--timeout", type=int, default=900,
                   help="等待回复超时（秒，默认 900）")
    s.add_argument("--profile", default="",
                   help="持久化 profile 目录（默认 state_dir/chatgpt-web-profile 或 ~/.astra-luna/chatgpt-web-profile）")
    s.set_defaults(fn=cmd_send)
    return p.parse_args(argv)


def main():
    args = parse_args(sys.argv[1:])
    if args.browser:
        os.environ[BROWSER_ENV] = args.browser
    if not args.profile:
        args.profile = default_profile()
    args.profile = str(Path(args.profile).resolve())
    Path(args.profile).mkdir(parents=True, exist_ok=True)
    try:
        # send/status 优先尝试 CDP 接管（快速失败，不阻塞）
        cdp = None
        if args.cmd in ("send", "status"):
            try:
                cdp = cdp_connect(args.cdp_port, timeout_s=5)
                log("接管运行中的浏览器（CDP 端口 %d）" % args.cdp_port)
            except Exception:
                cdp = None
        rc = args.fn(args, cdp) if args.cmd in ("send", "status") else args.fn(args, None)
        if cdp is not None:
            cdp.close()
    except SystemExit:
        raise
    sys.exit(rc)


if __name__ == "__main__":
    main()