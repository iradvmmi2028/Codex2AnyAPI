#!/usr/bin/env python3
"""WeChat Chatbot Open Platform adapter (微信对话开放平台) for astra-luna DIY.

Makes the non-OpenAI-shaped WeChat API usable as a DIY worker transport by
speaking the official /v2 protocol:

  1) POST {host}/v2/token
       headers: X-APPID, request_id, timestamp, nonce, sign
       sign   = md5(Token + str(ts) + nonce + md5(body))
       body   = b'' or {"account": "..."}
       -> data.access_token  (use as X-OPENAI-TOKEN, ~2h)

  2) POST {host}/v2/bot/query
       body = AES-256-CBC(base64) of JSON {query, env, userid, ...}
       AESKey = base64(EncodingAESKey + '=') -> 32 bytes; iv = key[:16]
       sign  = md5(Token + str(ts) + nonce + md5(body))
       -> decrypt response JSON {code, msg, data:{answer,...}}

Hosts:
  https://openaiapi.weixin.qq.com   (official docs)
  https://chatapi.weixin.qq.com     (alias used by some clients)

Config fields (diy.json):
  provider   = "wechat-chatapi" | "auto"
  base_url   = host (optional path ignored)
  appid      = platform APPID
  api_key    = platform Token (signing secret) OR a ready X-OPENAI-TOKEN
  aes_key    = EncodingAESKey (43-char base64 without padding)
  model      = display name (this platform has no OpenAI model catalog)
  env        = "online" | "debug"
  account    = optional admin id for /v2/token

Stdlib + cryptography/pycryptodome when available for AES.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

MAX_JSON_BYTES = 1_048_576
DEFAULT_HOSTS = (
    "https://openaiapi.weixin.qq.com",
    "https://chatapi.weixin.qq.com",
)
WECHAT_HOST_RE = re.compile(
    r"(openaiapi|chatapi)\.weixin\.qq\.com", re.I
)


def eprint(*args: Any) -> None:
    print("wechat-chatapi: " + " ".join(str(a) for a in args), file=sys.stderr)


def plugin_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def state_dir() -> Path:
    env = os.environ.get("ASTRA_LUNA_STATE_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return plugin_dir() / ".astra-luna-state"


def diy_path() -> Path:
    env = os.environ.get("ASTRA_DIY_CONFIG")
    if env:
        return Path(env).expanduser().resolve()
    return state_dir() / "diy.json"


def load_diy() -> dict[str, Any]:
    p = diy_path()
    if not p.is_file():
        return {}
    if p.stat().st_size > MAX_JSON_BYTES:
        raise RuntimeError(f"diy config larger than {MAX_JSON_BYTES} bytes: {p}")
    data = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise RuntimeError("diy config must be a JSON object")
    return data


def md5_hex(s: str | bytes) -> str:
    if isinstance(s, str):
        s = s.encode("utf-8")
    return hashlib.md5(s).hexdigest()


def now_ts() -> str:
    return str(int(time.time()))


def new_nonce() -> str:
    return uuid.uuid4().hex[:24]


def new_request_id() -> str:
    return str(uuid.uuid4())


def make_sign(token: str, timestamp: str, nonce: str, body: str | bytes) -> str:
    # Official: sign = md5(Token + str(unix_timestamp) + nonce + md5(body))
    if isinstance(body, bytes):
        bhash = md5_hex(body)
    else:
        bhash = md5_hex(body)
    return md5_hex(f"{token}{timestamp}{nonce}{bhash}")


def decode_aes_key(encoding_aes_key: str) -> bytes:
    raw = (encoding_aes_key or "").strip()
    if not raw:
        raise ValueError("aes_key (EncodingAESKey) is empty")
    if not raw.endswith("="):
        raw = raw + "="
    key = base64.b64decode(raw)
    if len(key) != 32:
        raise ValueError(f"EncodingAESKey must decode to 32 bytes, got {len(key)}")
    return key


def aes_cbc_encrypt(encoding_aes_key: str, plaintext: str) -> str:
    key = decode_aes_key(encoding_aes_key)
    iv = key[:16]
    data = plaintext.encode("utf-8")
    pad = 16 - (len(data) % 16)
    data = data + bytes([pad]) * pad
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        ct = enc.update(data) + enc.finalize()
    except Exception:
        from Crypto.Cipher import AES  # type: ignore

        ct = AES.new(key, AES.MODE_CBC, iv).encrypt(data)
    return base64.b64encode(ct).decode("ascii")


def aes_cbc_decrypt(encoding_aes_key: str, ciphertext_b64: str) -> str:
    key = decode_aes_key(encoding_aes_key)
    iv = key[:16]
    ct = base64.b64decode(ciphertext_b64)
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        data = dec.update(ct) + dec.finalize()
    except Exception:
        from Crypto.Cipher import AES  # type: ignore

        data = AES.new(key, AES.MODE_CBC, iv).decrypt(ct)
    pad = data[-1]
    if pad < 1 or pad > 16:
        # maybe already plain JSON
        text = data.decode("utf-8", errors="replace")
        return text
    data = data[:-pad]
    return data.decode("utf-8", errors="replace")


def normalize_host(base_url: str) -> str:
    url = (base_url or "").strip().rstrip("/")
    if not url:
        url = DEFAULT_HOSTS[0]
    if not re.match(r"^https?://", url, re.I):
        url = "https://" + url
    # strip trailing OpenAI-style path if present
    url = re.sub(r"/openai(/v\d+)?$", "", url)
    url = re.sub(r"/v\d+$", "", url)
    url = url.rstrip("/")
    return url


def is_wechat_cfg(cfg: dict[str, Any], base_url: str = "") -> bool:
    provider = str(cfg.get("provider") or "").lower()
    if provider in ("wechat-chatapi", "wechat", "wx-chatapi", "aispeech"):
        return True
    host = base_url or str(cfg.get("base_url") or "")
    return bool(WECHAT_HOST_RE.search(host))


def http_json(
    method: str,
    url: str,
    *,
    headers: dict[str, str],
    body: str | bytes | None = None,
    timeout: float = 30.0,
) -> tuple[int, Any, str]:
    data = None
    if body is not None:
        data = body.encode("utf-8") if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(MAX_JSON_BYTES + 1)
            if len(raw) > MAX_JSON_BYTES:
                raise RuntimeError("response too large")
            text = raw.decode("utf-8", errors="replace")
            try:
                parsed = json.loads(text) if text else None
            except json.JSONDecodeError:
                parsed = None
            return resp.status, parsed, text
    except urllib.error.HTTPError as exc:
        raw = exc.read(8192)
        text = raw.decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            parsed = None
        return exc.code, parsed, text
    except urllib.error.URLError as exc:
        raise RuntimeError(f"network error calling {url}: {exc.reason}") from exc
    except TimeoutError as exc:
        raise RuntimeError(f"timeout calling {url} ({timeout}s)") from exc


class WeChatChatApi:
    def __init__(self, cfg: dict[str, Any]):
        self.cfg = cfg
        self.host = normalize_host(str(cfg.get("base_url") or DEFAULT_HOSTS[0]))
        self.appid = str(cfg.get("appid") or cfg.get("app_id") or "").strip()
        self.token = str(cfg.get("wx_token") or cfg.get("api_key") or "").strip()
        self.aes_key = str(cfg.get("aes_key") or cfg.get("encoding_aes_key") or "").strip()
        self.model = str(cfg.get("model") or "wechat-chatbot").strip() or "wechat-chatbot"
        self.env = str(cfg.get("env") or "online").strip() or "online"
        self.account = str(cfg.get("account") or "").strip()
        self.timeout = float(cfg.get("timeout_sec") or 900)
        self._access_token = str(cfg.get("access_token") or "").strip()

    def ready_for_signed_api(self) -> bool:
        return bool(self.appid and self.token)

    def uses_access_token_header(self) -> bool:
        # Heuristic: if only api_key looks like a short-lived access token
        # (no appid/token pair), send it as X-OPENAI-TOKEN.
        return bool(self._access_token) and not self.ready_for_signed_api()

    def signed_headers(self, body: str | bytes, *, token_kind: str) -> dict[str, str]:
        ts = now_ts()
        nonce = new_nonce()
        rid = new_request_id()
        if token_kind == "access":
            auth = self._access_token
        else:
            auth = ""
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "astra-luna-wechat-chatapi/0.2.0",
            "request_id": rid,
            "timestamp": ts,
            "nonce": nonce,
            "sign": make_sign(self.token, ts, nonce, body),
        }
        if self.appid:
            headers["X-APPID"] = self.appid
        if auth:
            headers["X-OPENAI-TOKEN"] = auth
        return headers

    def fetch_access_token(self) -> str:
        if not self.ready_for_signed_api():
            if self._access_token:
                return self._access_token
            raise RuntimeError(
                "WeChat API needs platform APPID + Token (from chatbot.weixin.qq.com open API), "
                "or a valid X-OPENAI-TOKEN in access_token/api_key"
            )
        body = json.dumps({"account": self.account}, ensure_ascii=False) if self.account else "{}"
        url = self.host + "/v2/token"
        headers = self.signed_headers(body, token_kind="sign")
        # token endpoint: X-APPID + sign, no X-OPENAI-TOKEN yet
        headers.pop("X-OPENAI-TOKEN", None)
        status, parsed, text = http_json(
            "POST", url, headers=headers, body=body, timeout=min(self.timeout, 30.0)
        )
        if status != 200 or not isinstance(parsed, dict):
            raise RuntimeError(f"GET token failed http={status}: {text[:400]}")
        if parsed.get("code") not in (0, "0", None):
            raise RuntimeError(f"GET token business error: {parsed.get('code')} {parsed.get('msg')}")
        data = parsed.get("data") or {}
        token = ""
        if isinstance(data, dict):
            token = str(data.get("access_token") or data.get("accessToken") or "")
        if not token:
            raise RuntimeError(f"GET token returned no access_token: {text[:400]}")
        self._access_token = token
        return token

    def ensure_token(self) -> str:
        if self._access_token and self.ready_for_signed_api():
            # access tokens last ~2h; always refresh when we have APPID+Token
            return self.fetch_access_token()
        if self._access_token:
            return self._access_token
        return self.fetch_access_token()

    def query(self, message: str, *, userid: str | None = None) -> dict[str, Any]:
        token = self.ensure_token()
        payload_obj = {
            "query": message,
            "env": self.env,
            "first_priority_skills": [],
            "second_priority_skills": [],
            "user_name": "astra-diy",
            "avatar": "",
            "userid": userid or "astra-diy-worker",
        }
        plain = json.dumps(payload_obj, ensure_ascii=False)
        if self.aes_key:
            body = aes_cbc_encrypt(self.aes_key, plain)
            content_type = "text/plain"
        else:
            # Fallback: some gateways accept plain JSON (not official for bot/query).
            body = plain
            content_type = "application/json"
        headers = self.signed_headers(body, token_kind="access")
        headers["X-OPENAI-TOKEN"] = token
        headers["Content-Type"] = content_type
        if self.appid:
            headers["X-APPID"] = self.appid
        url = self.host + "/v2/bot/query"
        status, parsed, text = http_json(
            "POST", url, headers=headers, body=body, timeout=self.timeout
        )
        raw_body = text
        if self.aes_key and text and not text.lstrip().startswith("{"):
            try:
                raw_body = aes_cbc_decrypt(self.aes_key, text.strip())
                parsed = json.loads(raw_body)
            except Exception as exc:
                raise RuntimeError(
                    f"bot/query http={status}, decrypt/parse failed: {exc}; raw={text[:300]}"
                ) from exc
        if status != 200:
            raise RuntimeError(f"bot/query http={status}: {raw_body[:400]}")
        if not isinstance(parsed, dict):
            raise RuntimeError(f"bot/query non-json response: {raw_body[:400]}")
        code = parsed.get("code")
        if code not in (0, "0", None):
            raise RuntimeError(f"bot/query business error: {code} {parsed.get('msg')} {raw_body[:300]}")
        data = parsed.get("data") or {}
        if not isinstance(data, dict):
            data = {"answer": str(data)}
        answer = data.get("answer")
        if answer is None:
            answer = data.get("text") or data.get("short_answer") or ""
        return {
            "ok": True,
            "provider": "wechat-chatapi",
            "host": self.host,
            "appid": self.appid,
            "model": self.model,
            "http_status": status,
            "answer": answer if isinstance(answer, str) else json.dumps(answer, ensure_ascii=False),
            "status": data.get("status"),
            "skill_name": data.get("skill_name"),
            "intent_name": data.get("intent_name"),
            "raw": parsed,
        }

    def probe(self, message: str = "ping") -> dict[str, Any]:
        if not self.ready_for_signed_api() and not self._access_token and not self.token:
            return {
                "ok": False,
                "provider": "wechat-chatapi",
                "error": "missing credentials: need appid + api_key(Token), or access_token",
                "hint": "在 chatbot.weixin.qq.com 申请开放 API，填写 APPID/Token/AESKey",
            }
        # If we only have a user-supplied "api_key" that is not a signing Token
        # (e.g. opaque blob) and no appid/aes_key, report clearly.
        if not self.ready_for_signed_api() and not self.aes_key and self.token:
            # try using token as X-OPENAI-TOKEN + plain JSON query
            self._access_token = self.token
            try:
                return self.query(message)
            except Exception as exc:
                return {
                    "ok": False,
                    "provider": "wechat-chatapi",
                    "error": str(exc),
                    "hint": "需要平台 APPID + Token + EncodingAESKey；仅有单串凭证通常不够",
                }
        try:
            return self.query(message)
        except Exception as exc:
            return {
                "ok": False,
                "provider": "wechat-chatapi",
                "error": str(exc),
                "host": self.host,
                "appid": self.appid,
            }

    def models(self) -> list[str]:
        # This platform has no OpenAI model catalog; surface the bot identity.
        ids = []
        if self.model:
            ids.append(self.model)
        if self.appid:
            ids.append(f"wx-bot:{self.appid}")
        if not ids:
            ids.append("wechat-chatbot")
        return ids


def markdown_from_answer(result: dict[str, Any]) -> str:
    answer = result.get("answer") or ""
    lines = [
        "# WeChat chatbot worker result",
        "",
        f"- provider: wechat-chatapi",
        f"- host: {result.get('host')}",
        f"- model: {result.get('model')}",
        f"- skill: {result.get('skill_name') or ''}",
        f"- status: {result.get('status') or ''}",
        "",
        "## Answer",
        "",
        str(answer),
        "",
        "## Note",
        "",
        "微信对话开放平台是智能问答机器人，不是通用代码大模型。",
        "结果按原文回传；GPT-6 Astra 负责审核是否满足 execution packet 验收标准。",
    ]
    return "\n".join(lines) + "\n"


def cmd_show(_args: argparse.Namespace) -> int:
    cfg = load_diy()
    host = normalize_host(str(cfg.get("base_url") or ""))
    wx = is_wechat_cfg(cfg, host)
    out = {
        "provider": cfg.get("provider") or ("wechat-chatapi" if wx else "openai-compatible"),
        "wechat_detected": wx,
        "base_url": cfg.get("base_url") or "",
        "resolved_host": host,
        "appid_set": bool(cfg.get("appid") or cfg.get("app_id")),
        "token_set": bool(cfg.get("wx_token") or cfg.get("api_key")),
        "aes_key_set": bool(cfg.get("aes_key") or cfg.get("encoding_aes_key")),
        "model": cfg.get("model") or "",
        "env": cfg.get("env") or "online",
        "enabled": bool(cfg.get("enabled")),
        "config_path": str(diy_path()),
        "models": WeChatChatApi(cfg).models() if wx else [],
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    p = diy_path()
    cfg = load_diy()
    if args.provider is not None:
        cfg["provider"] = args.provider
    if args.base_url is not None:
        cfg["base_url"] = args.base_url
    if args.appid is not None:
        cfg["appid"] = args.appid
    if args.api_key is not None:
        cfg["api_key"] = args.api_key
        cfg["wx_token"] = args.api_key
    if args.aes_key is not None:
        cfg["aes_key"] = args.aes_key
    if args.model is not None:
        cfg["model"] = args.model
    if args.env is not None:
        cfg["env"] = args.env
    if args.account is not None:
        cfg["account"] = args.account
    if args.enabled is not None:
        cfg["enabled"] = str(args.enabled).lower() in ("1", "true", "yes", "on")
    if args.replace_luna is not None:
        cfg["replace_luna"] = str(args.replace_luna).lower() in ("1", "true", "yes", "on")
    if args.timeout_sec is not None:
        cfg["timeout_sec"] = int(args.timeout_sec)
    # auto-detect provider
    if not cfg.get("provider") and is_wechat_cfg(cfg, str(cfg.get("base_url") or "")):
        cfg["provider"] = "wechat-chatapi"
    if str(cfg.get("base_url") or "").find("weixin.qq.com") >= 0 and not cfg.get("provider"):
        cfg["provider"] = "wechat-chatapi"
    p.parent.mkdir(parents=True, exist_ok=True)
    cfg["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    tmp = p.with_suffix(p.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)
    print(json.dumps({"saved": str(p), "provider": cfg.get("provider"), "appid": cfg.get("appid"), "model": cfg.get("model")}, ensure_ascii=False, indent=2))
    return 0


def cmd_test(_args: argparse.Namespace) -> int:
    cfg = load_diy()
    wx = WeChatChatApi(cfg)
    result = wx.probe("ping")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 2


def cmd_models(_args: argparse.Namespace) -> int:
    cfg = load_diy()
    wx = WeChatChatApi(cfg)
    print(json.dumps({"ok": True, "provider": "wechat-chatapi", "models": wx.models(), "note": "微信对话平台无 OpenAI 模型目录，列出的是机器人身份"}, ensure_ascii=False, indent=2))
    return 0


def cmd_chat(args: argparse.Namespace) -> int:
    cfg = load_diy()
    wx = WeChatChatApi(cfg)
    result = wx.query(args.message)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    cfg = load_diy()
    if not cfg.get("enabled", False):
        eprint("DIY worker is not enabled")
        return 3
    payload_path = Path(args.payload)
    if not payload_path.is_file():
        eprint(f"payload not found: {payload_path}")
        return 1
    payload_text = payload_path.read_text(encoding="utf-8")
    # WeChat bots are FAQ/dialog oriented; still send the packet as one query
    # so Astra can review whatever the bot returns. Truncate if absurdly long.
    max_q = 3500
    message = payload_text.strip()
    if len(message) > max_q:
        message = message[:max_q] + "\n...[payload truncated for WeChat bot query]"
    if args.message:
        message = args.message
    wx = WeChatChatApi(cfg)
    try:
        result = wx.query(message)
    except Exception as exc:
        eprint(str(exc))
        return 2
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    md = args.format == "markdown" or True
    content = markdown_from_answer(result) if md else (result.get("answer") or "")
    tmp = out.with_suffix(out.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(content if content.endswith("\n") else content + "\n", encoding="utf-8")
    os.replace(tmp, out)
    report = {
        "ok": True,
        "transport": "diy-openai",
        "provider": "wechat-chatapi",
        "host": wx.host,
        "model": wx.model,
        "packet_id": args.packet_id or "",
        "result_file": str(out),
        "result_bytes": out.stat().st_size,
        "answer_preview": (result.get("answer") or "")[:200],
        "skill_name": result.get("skill_name"),
        "status": result.get("status"),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="wechat-chatapi.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show")
    sp = sub.add_parser("set")
    sp.add_argument("--provider")
    sp.add_argument("--base-url", dest="base_url")
    sp.add_argument("--appid")
    sp.add_argument("--api-key", dest="api_key")
    sp.add_argument("--aes-key", dest="aes_key")
    sp.add_argument("--model")
    sp.add_argument("--env")
    sp.add_argument("--account")
    sp.add_argument("--enabled")
    sp.add_argument("--replace-luna", dest="replace_luna")
    sp.add_argument("--timeout-sec", dest="timeout_sec")
    sub.add_parser("test")
    sub.add_parser("models")
    ch = sub.add_parser("chat")
    ch.add_argument("--message", required=True)
    rn = sub.add_parser("run")
    rn.add_argument("--payload", required=True)
    rn.add_argument("--output", required=True)
    rn.add_argument("--packet-id", dest="packet_id", default="")
    rn.add_argument("--message")
    rn.add_argument("--format", default="markdown")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    handlers = {
        "show": cmd_show,
        "set": cmd_set,
        "test": cmd_test,
        "models": cmd_models,
        "chat": cmd_chat,
        "run": cmd_run,
    }
    try:
        return handlers[args.cmd](args)
    except SystemExit as exc:
        code = exc.code
        return 0 if code is None else (code if isinstance(code, int) else 1)
    except Exception as exc:
        eprint(str(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
