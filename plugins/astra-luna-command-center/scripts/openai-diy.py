#!/usr/bin/env python3
"""OpenAI-compatible DIY worker client for astra-luna-command-center.

Astra (GPT-6, this Codex session) remains the command tower. This script only
talks to a user-configured OpenAI-compatible endpoint (local or remote
provider) that REPLACES the gpt-5.6-luna worker when DIY is enabled.

Stdlib only (urllib). Never prints the full API key.

Subcommands:
  set       write/merge diy.json fields
  show      print diy status (api_key masked)
  clear     disable DIY / wipe credentials
  test      connection + auth probe (GET /models)
  models    list model ids from the provider
  chat      one-shot chat completion
  run       execute a packet payload via chat/completions and write result.md
  schema    print the settings field schema (for UI / skill)

Exit: 0 ok | 1 usage/validation | 2 runtime/network | 3 config incomplete
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MAX_JSON_BYTES = 1_048_576
WECHAT_HOST_RE = re.compile(r"(openaiapi|chatapi)\.weixin\.qq\.com", re.I)
WORKER_PREAMBLE = (
    "You are the bounded astra_worker execution agent reporting to GPT-6 Astra "
    "(control tower). Complete only the assigned subtask in the execution packet. "
    "Stay strictly in scope and file boundaries. Do not spawn agents or change "
    "architecture. Verify when practical. Return a result with: "
    "(1) exact result, (2) files changed/inspected, (3) checks run, "
    "(4) verification, (5) remaining risks. Prefer Markdown (.md) output. "
    "If you edit source code, list every file path and the change summary.\n\n"
)

def _load_wechat_adapter():
    try:
        import importlib.util

        path = Path(__file__).resolve().parent / "wechat-chatapi.py"
        if not path.is_file():
            return None
        spec = importlib.util.spec_from_file_location("wechat_chatapi", path)
        if not spec or not spec.loader:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


def is_wechat_config(cfg: dict[str, Any]) -> bool:
    """True when the endpoint is a WeChat host (gateway or official /v2)."""
    provider = str(cfg.get("provider") or "").lower()
    if provider.startswith("wechat") or provider in ("aispeech", "wx-chatapi"):
        return True
    return bool(WECHAT_HOST_RE.search(str(cfg.get("base_url") or "")))


def use_wechat_v2_adapter(cfg: dict[str, Any]) -> bool:
    """Use official /v2 APPID+Token+AES only when those credentials exist.

    SpiderCode / WeChat OpenAI gateway path (default):
      POST https://chatapi.weixin.qq.com/openai/v1/chat/completions
      Authorization: Bearer <key>
      model = Deepseek-v4-flash
    — NO APPID / EncodingAESKey required.
    """
    provider = str(cfg.get("provider") or "").lower()
    if provider in ("openai-compatible", "wechat-openai-gateway", "wechat-gateway"):
        return False
    has_app = bool(cfg.get("appid") or cfg.get("app_id"))
    has_secret = bool(cfg.get("aes_key") or cfg.get("encoding_aes_key"))
    if provider in ("wechat-chatapi", "wx-v2", "aispeech-v2"):
        return has_app and has_secret
    # auto: only v2 when full official triple-ish credentials present
    return has_app and has_secret


def wechat_route(cfg: dict[str, Any], action: str, extra: dict[str, Any] | None = None) -> int:
    """Delegate to wechat-chatapi.py (official /v2). Returns its exit code."""
    mod = _load_wechat_adapter()
    if mod is None:
        eprint("wechat adapter missing: scripts/wechat-chatapi.py")
        return 2
    argv = [action]
    if action == "chat":
        argv += ["--message", (extra or {}).get("message", "ping")]
    if action == "run":
        argv += ["--payload", (extra or {}).get("payload", ""), "--output", (extra or {}).get("output", "")]
        pid = (extra or {}).get("packet_id") or ""
        if pid:
            argv += ["--packet-id", pid]
    return int(mod.main(argv) or 0)


def openai_chat(cfg: dict[str, Any], messages: list[dict[str, str]], model: str | None = None) -> tuple[str, dict[str, Any]]:
    base, key, cfg_model = _require_ready_or_die(cfg, need_model=False)
    use_model = (model or cfg_model or "").strip()
    if not use_model:
        raise RuntimeError("model is required (e.g. Deepseek-v4-flash)")
    timeout = float(cfg.get("timeout_sec") or 900)
    body = {
        "model": use_model,
        "messages": messages,
        "temperature": float(cfg.get("temperature", 0.2)),
        "stream": False,
    }
    status, parsed, text = http_json(
        "POST", base + "/chat/completions", api_key=key, body=body, timeout=timeout
    )
    if status != 200 or not isinstance(parsed, dict):
        raise RuntimeError(f"chat/completions failed http={status}: {(text or '')[:400]}")
    content = ""
    choices = parsed.get("choices") or []
    if choices and isinstance(choices[0], dict):
        msg = choices[0].get("message") or {}
        if isinstance(msg, dict):
            content = str(msg.get("content") or "")
        if not content:
            content = str(choices[0].get("text") or "")
    if not content:
        raise RuntimeError("chat/completions returned empty content")
    meta = {
        "id": parsed.get("id"),
        "model": parsed.get("model") or use_model,
        "usage": parsed.get("usage"),
        "http_status": status,
        "provider": "openai-compatible",
        "base_url": base,
    }
    return content, meta


def openai_test(cfg: dict[str, Any]) -> int:
    base, key, model = _require_ready_or_die(cfg, need_model=False)
    model = (model or "").strip() or "Deepseek-v4-flash"
    t0 = time.time()
    # Primary probe for WeChat gateway: POST chat/completions (GET /models is non-standard)
    try:
        content, meta = openai_chat(
            cfg,
            [{"role": "user", "content": "ping"}],
            model=model,
        )
        out = {
            "ok": True,
            "stage": "chat/completions",
            "base_url": base,
            "model": meta.get("model"),
            "latency_ms": int((time.time() - t0) * 1000),
            "content_preview": content[:200],
            "usage": meta.get("usage"),
            "provider": "openai-compatible",
            "note": "WeChat/SpiderCode gateway verified via chat/completions (no APPID/AESKey required)",
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0
    except RuntimeError as exc:
        # fallback: try GET /models for true OpenAI-compatible hosts
        try:
            status, parsed, text = http_json(
                "GET", base + "/models", api_key=key, timeout=min(float(cfg.get("timeout_sec") or 30), 30.0)
            )
            ids = []
            if isinstance(parsed, dict):
                items = parsed.get("data") or parsed.get("models") or []
                if isinstance(items, list):
                    for it in items:
                        if isinstance(it, dict) and it.get("id"):
                            ids.append(str(it["id"]))
                        elif isinstance(it, str):
                            ids.append(it)
            if status == 200:
                print(json.dumps({
                    "ok": True,
                    "stage": "models",
                    "http_status": status,
                    "base_url": base,
                    "model_configured": model,
                    "model_listed": (model in ids) if ids else None,
                    "models_count": len(ids),
                    "models_sample": ids[:20],
                    "note": "chat/completions failed; /models OK — check model name",
                    "chat_error": str(exc),
                }, ensure_ascii=False, indent=2))
                return 0
        except RuntimeError:
            pass
        print(json.dumps({
            "ok": False,
            "stage": "chat/completions",
            "base_url": base,
            "model": model,
            "error": str(exc),
        }, ensure_ascii=False, indent=2))
        return 2

SETTINGS_FIELDS = [
    {
        "key": "provider",
        "label": "Provider",
        "type": "select",
        "options": ["openai-compatible", "wechat-chatapi"],
        "default": "openai-compatible",
        "help": "openai-compatible: 标准 /v1/chat/completions；wechat-chatapi: 微信对话开放平台 /v2 适配。",
    },
    {
        "key": "base_url",
        "label": "Base URL",
        "type": "text",
        "placeholder": "http://127.0.0.1:11434/v1 或 https://openaiapi.weixin.qq.com",
        "required": True,
        "help": "OpenAI 兼容根地址，或微信对话平台 host（chatapi/openaiapi.weixin.qq.com）。",
    },
    {
        "key": "api_key",
        "label": "API Key / Token",
        "type": "password",
        "placeholder": "sk-... 或微信平台 Token",
        "required": True,
        "help": "OpenAI: Bearer key；微信: 平台 Token（与 APPID 一起签名）。Env ASTRA_DIY_API_KEY 可覆盖。",
    },
    {
        "key": "appid",
        "label": "WeChat APPID",
        "type": "text",
        "placeholder": "chatbot.weixin.qq.com 申请的 APPID",
        "required": False,
        "help": "仅 wechat-chatapi 需要。",
    },
    {
        "key": "aes_key",
        "label": "WeChat EncodingAESKey",
        "type": "password",
        "placeholder": "43 位 EncodingAESKey",
        "required": False,
        "help": "仅 wechat-chatapi 需要；bot/query 请求体 AES-CBC 加密。",
    },
    {
        "key": "model",
        "label": "Model / Bot",
        "type": "text",
        "placeholder": "deepseek-chat 或 wechat-bot",
        "required": True,
        "help": "OpenAI 兼容: 模型 id；微信: 机器人显示名（无模型目录）。",
    },
    {
        "key": "env",
        "label": "WeChat env",
        "type": "text",
        "placeholder": "online / debug",
        "required": False,
        "help": "仅 wechat-chatapi：机器人环境。",
    },
    {
        "key": "enabled",
        "label": "Enable DIY worker",
        "type": "bool",
        "default": True,
        "help": "When true + replace_luna, dispatch defaults to diy-openai instead of local-worker.",
    },
    {
        "key": "replace_luna",
        "label": "Replace gpt-5.6-luna",
        "type": "bool",
        "default": True,
        "help": "Astra still plans/reviews; only the worker model is replaced.",
    },
    {
        "key": "temperature",
        "label": "Temperature",
        "type": "number",
        "default": 0.2,
        "help": "Chat completion sampling temperature.",
    },
    {
        "key": "timeout_sec",
        "label": "Timeout (seconds)",
        "type": "number",
        "default": 900,
        "help": "HTTP timeout for chat completions.",
    },
]


def eprint(*args: Any) -> None:
    print("openai-diy: " + " ".join(str(a) for a in args), file=sys.stderr)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"corrupt diy config {p}: {exc}") from exc
    if not isinstance(data, dict):
        raise RuntimeError(f"diy config must be a JSON object: {p}")
    return data


def save_diy(data: dict[str, Any]) -> Path:
    p = diy_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    data = dict(data)
    data["updated_at"] = utc_now()
    tmp = p.with_suffix(p.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass  # Windows: best-effort; file still lands under state dir
    return p


def mask_key(key: str | None) -> str:
    if not key:
        return ""
    if len(key) <= 8:
        return "*" * len(key)
    return key[:3] + "*" * (len(key) - 7) + key[-4:]


def normalize_base_url(raw: str) -> str:
    url = (raw or "").strip().rstrip("/")
    if not url:
        return ""
    if not re.match(r"^https?://", url, re.I):
        raise ValueError("base_url must start with http:// or https://")
    # Accept full chat/completions URL (SpiderCode style)
    url = re.sub(r"/chat/completions$", "", url, flags=re.I)
    # WeChat OpenAI gateway: keep .../openai/v1
    if WECHAT_HOST_RE.search(url):
        if re.search(r"/openai/v\d+$", url, re.I):
            return url
        if re.search(r"/openai$", url, re.I):
            return url + "/v1"
        if re.search(r"/v\d+$", url, re.I):
            return url
        return url + "/openai/v1"
    if url.endswith("/v1") or "/v1/" in url:
        return url
    if re.search(r"/v\d+$", url):
        return url
    return url + "/v1"


def resolve_api_key(cfg: dict[str, Any]) -> str:
    env = os.environ.get("ASTRA_DIY_API_KEY", "").strip()
    if env:
        return env
    return str(cfg.get("api_key") or "").strip()


def require_ready(cfg: dict[str, Any], *, need_model: bool = True) -> tuple[str, str, str]:
    base = normalize_base_url(str(cfg.get("base_url") or ""))
    key = resolve_api_key(cfg)
    model = str(cfg.get("model") or "").strip()
    missing = []
    if not base:
        missing.append("base_url")
    if not key:
        missing.append("api_key")
    if need_model and not model:
        missing.append("model")
    if missing:
        raise SystemExit(3)
    # re-raise with detail after caller catches; helper used via try
    return base, key, model


def _require_ready_or_die(cfg: dict[str, Any], *, need_model: bool = True) -> tuple[str, str, str]:
    try:
        return require_ready(cfg, need_model=need_model)
    except SystemExit:
        key = resolve_api_key(cfg)
        miss = []
        if not str(cfg.get("base_url") or "").strip():
            miss.append("base_url")
        if not key:
            miss.append("api_key")
        if need_model and not str(cfg.get("model") or "").strip():
            miss.append("model")
        eprint("config incomplete; missing: " + ", ".join(miss or ["unknown"]))
        eprint("set them via: astra-luna.ps1 diy-set -BaseUrl ... -ApiKey ... -Model ...")
        eprint("or open the settings dialog: astra-luna.ps1 diy-settings")
        raise SystemExit(3)


def http_json(
    method: str,
    url: str,
    *,
    api_key: str,
    body: dict[str, Any] | None = None,
    timeout: float = 60.0,
) -> tuple[int, Any, str]:
    data = None
    headers = {
        "Accept": "application/json",
        "User-Agent": "astra-luna-openai-diy/0.2.0",
    }
    if api_key:
        headers["Authorization"] = "Bearer " + api_key
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(MAX_JSON_BYTES + 1)
            if len(raw) > MAX_JSON_BYTES:
                raise RuntimeError(f"response larger than {MAX_JSON_BYTES} bytes")
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


def cmd_schema(_args: argparse.Namespace) -> int:
    print(json.dumps({"config_path": str(diy_path()), "fields": SETTINGS_FIELDS}, ensure_ascii=False, indent=2))
    return 0


def cmd_show(_args: argparse.Namespace) -> int:
    cfg = load_diy()
    key = resolve_api_key(cfg)
    wx_host = is_wechat_config(cfg)
    v2 = use_wechat_v2_adapter(cfg)
    out = {
        "config_path": str(diy_path()),
        "exists": diy_path().is_file(),
        "provider": cfg.get("provider") or ("wechat-openai-gateway" if wx_host and not v2 else ("wechat-chatapi-v2" if v2 else "openai-compatible")),
        "wechat_host": wx_host,
        "wechat_v2_adapter": v2,
        "enabled": bool(cfg.get("enabled", False)),
        "replace_luna": bool(cfg.get("replace_luna", True)),
        "base_url": cfg.get("base_url") or "",
        "base_url_normalized": "",
        "model": cfg.get("model") or "",
        "appid_set": bool(cfg.get("appid") or cfg.get("app_id")),
        "aes_key_set": bool(cfg.get("aes_key") or cfg.get("encoding_aes_key")),
        "api_key_masked": mask_key(key),
        "api_key_source": "env:ASTRA_DIY_API_KEY" if os.environ.get("ASTRA_DIY_API_KEY") else ("config" if cfg.get("api_key") else "missing"),
        "temperature": cfg.get("temperature", 0.2),
        "timeout_sec": cfg.get("timeout_sec", 900),
        "updated_at": cfg.get("updated_at") or "",
        "ready": False,
        "worker_route": "gpt-5.6-luna (local-worker)",
    }
    try:
        if cfg.get("base_url"):
            out["base_url_normalized"] = normalize_base_url(str(cfg["base_url"]))
    except ValueError as exc:
        out["base_url_error"] = str(exc)
    if v2:
        ready = bool(out["base_url_normalized"] and key and out["model"] and out["enabled"] and out["appid_set"])
        if ready and out["replace_luna"]:
            out["worker_route"] = f"diy-openai/wechat-v2 -> {out['model']} @ {out['base_url_normalized']}"
        out["hint"] = "官方 /v2 协议（需要 APPID+Token+AESKey）"
    else:
        # OpenAI-compatible path — WeChat SpiderCode gateway included
        need_key = True if not wx_host else True
        ready = bool(out["base_url_normalized"] and (key or not need_key) and out["model"] and out["enabled"])
        if wx_host and not key:
            ready = False
        out["ready"] = ready
        if ready and out["replace_luna"]:
            out["worker_route"] = f"diy-openai -> {out['model']} @ {out['base_url_normalized']}"
        if wx_host:
            out["hint"] = "微信网关按 OpenAI 兼容调用：Bearer + POST /chat/completions；无需 APPID/AESKey（与 SpiderCode 一致）"
    out["ready"] = ready
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0 if (not out["enabled"] or ready or not out["enabled"]) else 0


def cmd_set(args: argparse.Namespace) -> int:
    cfg = load_diy()
    if getattr(args, "provider", None) is not None:
        cfg["provider"] = args.provider
    if getattr(args, "appid", None) is not None:
        cfg["appid"] = args.appid
    if getattr(args, "aes_key", None) is not None:
        cfg["aes_key"] = args.aes_key
    if getattr(args, "wx_env", None) is not None:
        cfg["env"] = args.wx_env
    if args.base_url is not None:
        raw = args.base_url
        if raw and WECHAT_HOST_RE.search(raw) and not getattr(args, "provider", None):
            # SpiderCode-style gateway: default provider is OpenAI-compatible, not /v2
            cfg["provider"] = "wechat-openai-gateway"
        cfg["base_url"] = normalize_base_url(raw) if raw else ""
    if args.api_key is not None:
        cfg["api_key"] = args.api_key
        if use_wechat_v2_adapter(cfg):
            cfg["wx_token"] = args.api_key
    if args.model is not None:
        cfg["model"] = args.model.strip()
    if args.enabled is not None:
        cfg["enabled"] = _as_bool(args.enabled)
    if args.replace_luna is not None:
        cfg["replace_luna"] = _as_bool(args.replace_luna)
    if args.temperature is not None:
        cfg["temperature"] = float(args.temperature)
    if args.timeout_sec is not None:
        cfg["timeout_sec"] = int(args.timeout_sec)
    path = save_diy(cfg)
    print(json.dumps({
        "saved": str(path),
        "provider": cfg.get("provider") or ("wechat-openai-gateway" if is_wechat_config(cfg) else "openai-compatible"),
        "enabled": bool(cfg.get("enabled")),
        "model": cfg.get("model") or "",
        "base_url": cfg.get("base_url") or "",
        "appid_set": bool(cfg.get("appid")),
        "v2_adapter": use_wechat_v2_adapter(cfg),
        "replace_luna": bool(cfg.get("replace_luna", True)),
    }, ensure_ascii=False, indent=2))
    return 0


def _as_bool(v: Any) -> bool:
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if s in ("1", "true", "yes", "on", "y"):
        return True
    if s in ("0", "false", "no", "off", "n"):
        return False
    raise SystemExit(f"openai-diy: invalid boolean: {v}")


def cmd_clear(_args: argparse.Namespace) -> int:
    cfg = load_diy()
    cfg["enabled"] = False
    cfg["api_key"] = ""
    path = save_diy(cfg)
    print(json.dumps({"cleared": str(path), "enabled": False}, ensure_ascii=False, indent=2))
    return 0


def cmd_test(_args: argparse.Namespace) -> int:
    cfg = load_diy()
    if use_wechat_v2_adapter(cfg):
        return wechat_route(cfg, "test")
    # OpenAI-compatible probe: POST chat/completions (WeChat gateway included)
    return openai_test(cfg)


def cmd_models(_args: argparse.Namespace) -> int:
    cfg = load_diy()
    if use_wechat_v2_adapter(cfg):
        return wechat_route(cfg, "models")
    base, key, model = _require_ready_or_die(cfg, need_model=False)
    # WeChat gateway has non-standard /models; return configured model + try /models
    if WECHAT_HOST_RE.search(base):
        listed = []
        try:
            status, parsed, _ = http_json("GET", base + "/models", api_key=key, timeout=15)
            if status == 200 and isinstance(parsed, dict):
                items = parsed.get("data") or parsed.get("models") or []
                if isinstance(items, list):
                    for it in items:
                        if isinstance(it, dict) and it.get("id"):
                            listed.append(str(it["id"]))
                        elif isinstance(it, str):
                            listed.append(it)
        except Exception:
            pass
        if not listed and model:
            listed = [model]
        if not listed:
            listed = ["Deepseek-v4-flash"]
        print(json.dumps({
            "ok": True,
            "provider": "wechat-openai-gateway",
            "base_url": base,
            "note": "微信网关 /models 非标准；以下为可用/已配置模型，请手选",
            "models": listed,
            "model_configured": model,
        }, ensure_ascii=False, indent=2))
        return 0
    base, key, _ = _require_ready_or_die(cfg, need_model=False)
    timeout = float(cfg.get("timeout_sec") or 900)
    try:
        status, parsed, text = http_json("GET", base + "/models", api_key=key, timeout=min(timeout, 30.0))
    except RuntimeError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2))
        return 2
    ids: list[str] = []
    if isinstance(parsed, dict):
        items = parsed.get("data") or parsed.get("models") or []
        if isinstance(items, list):
            for it in items:
                if isinstance(it, dict) and it.get("id"):
                    ids.append(str(it["id"]))
                elif isinstance(it, str):
                    ids.append(it)
    print(json.dumps({"ok": status == 200, "http_status": status, "base_url": base, "count": len(ids), "models": ids}, ensure_ascii=False, indent=2))
    return 0 if status == 200 else 2


def _chat_completion(
    cfg: dict[str, Any],
    *,
    messages: list[dict[str, str]],
    model: str,
    temperature: float | None = None,
) -> tuple[str, dict[str, Any]]:
    base, key, _ = _require_ready_or_die(cfg, need_model=False)
    if not model:
        raise SystemExit(3)
    timeout = float(cfg.get("timeout_sec") or 900)
    temp = cfg.get("temperature", 0.2) if temperature is None else temperature
    body = {
        "model": model,
        "messages": messages,
        "temperature": float(temp),
        "stream": False,
    }
    try:
        status, parsed, text = http_json(
            "POST",
            base + "/chat/completions",
            api_key=key,
            body=body,
            timeout=timeout,
        )
    except RuntimeError as exc:
        raise RuntimeError(str(exc)) from exc
    if status != 200 or not isinstance(parsed, dict):
        snippet = (text or "")[:500]
        raise RuntimeError(f"chat/completions failed http={status}: {snippet}")
    content = ""
    choices = parsed.get("choices") or []
    if choices and isinstance(choices[0], dict):
        msg = choices[0].get("message") or {}
        if isinstance(msg, dict):
            content = str(msg.get("content") or "")
        if not content:
            content = str(choices[0].get("text") or "")
    if not content:
        raise RuntimeError("chat/completions returned empty content")
    meta = {
        "id": parsed.get("id"),
        "model": parsed.get("model") or model,
        "usage": parsed.get("usage"),
        "http_status": status,
    }
    return content, meta


def cmd_chat(args: argparse.Namespace) -> int:
    cfg = load_diy()
    if use_wechat_v2_adapter(cfg):
        return wechat_route(cfg, "chat", {"message": args.message})
    try:
        content, meta = openai_chat(
            cfg, [{"role": "user", "content": args.message}], model=args.model
        )
    except (RuntimeError, SystemExit) as exc:
        eprint(str(exc))
        return 2 if not isinstance(exc, SystemExit) else int(exc.code or 2)
    print(json.dumps({"ok": True, "model": meta.get("model"), "usage": meta.get("usage"), "content": content}, ensure_ascii=False, indent=2))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    cfg = load_diy()
    if use_wechat_v2_adapter(cfg):
        return wechat_route(
            cfg,
            "run",
            {
                "payload": args.payload,
                "output": args.output,
                "packet_id": args.packet_id or "",
                "message": getattr(args, "message", None) or "",
            },
        )
    if not cfg.get("enabled", False):
        eprint("DIY worker is not enabled. Run diy-set -Enabled true or /astra-Diy first.")
        return 3
    if cfg.get("replace_luna", True) is False and not args.force:
        eprint("replace_luna=false; pass --force to run anyway, or diy-set -ReplaceLuna true")
        return 3
    base, key, model = _require_ready_or_die(cfg, need_model=True)
    if args.model:
        model = args.model.strip()
    if not model:
        eprint("model not set; pass --model or diy-set -Model (e.g. Deepseek-v4-flash)")
        return 3
    payload_path = Path(args.payload)
    if not payload_path.is_file():
        eprint(f"payload not found: {payload_path}")
        return 1
    if payload_path.stat().st_size > MAX_JSON_BYTES:
        eprint(f"payload larger than {MAX_JSON_BYTES} bytes")
        return 2
    payload_text = payload_path.read_text(encoding="utf-8")
    prompt = args.prompt or WORKER_PREAMBLE
    if args.packet_id:
        prompt = (
            f"You are the bounded astra_worker execution agent reporting to GPT-6 Astra. "
            f"Complete only the assigned subtask in the execution packet ({args.packet_id}). "
            f"Stay strictly in scope and file boundaries. Do not spawn agents or change architecture. "
            f"Verify when practical. Return a result with: (1) exact result, (2) files changed/inspected, "
            f"(3) checks run, (4) verification, (5) remaining risks.\n\n"
        )
    messages = [
        {"role": "system", "content": args.system or "You are a careful software engineering worker. Output Markdown."},
        {"role": "user", "content": prompt + payload_text},
    ]
    try:
        content, meta = openai_chat(cfg, messages=messages, model=model)
    except SystemExit as exc:
        return int(exc.code or 3)
    except RuntimeError as exc:
        eprint(str(exc))
        return 2
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(out.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(content if content.endswith("\n") else content + "\n", encoding="utf-8")
    os.replace(tmp, out)
    report = {
        "ok": True,
        "transport": "diy-openai",
        "provider": "openai-compatible",
        "provider_base_url": base,
        "model": meta.get("model") or model,
        "packet_id": args.packet_id or "",
        "result_file": str(out),
        "result_bytes": out.stat().st_size,
        "usage": meta.get("usage"),
        "id": meta.get("id"),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="openai-diy.py", description="OpenAI-compatible DIY worker for astra-luna")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("schema", help="print settings field schema")

    sub.add_parser("show", help="show diy status (api key masked)")

    sp = sub.add_parser("set", help="set diy config fields")
    sp.add_argument("--provider", default=None)
    sp.add_argument("--base-url", dest="base_url", default=None)
    sp.add_argument("--api-key", dest="api_key", default=None)
    sp.add_argument("--appid", default=None)
    sp.add_argument("--aes-key", dest="aes_key", default=None)
    sp.add_argument("--wx-env", dest="wx_env", default=None)
    sp.add_argument("--model", default=None)
    sp.add_argument("--enabled", default=None)
    sp.add_argument("--replace-luna", dest="replace_luna", default=None)
    sp.add_argument("--temperature", default=None)
    sp.add_argument("--timeout-sec", dest="timeout_sec", default=None)

    sub.add_parser("clear", help="disable diy and clear api key")

    sub.add_parser("test", help="test connection/auth against the provider")

    sub.add_parser("models", help="list models from the provider")

    ch = sub.add_parser("chat", help="one-shot chat completion")
    ch.add_argument("--message", required=True)
    ch.add_argument("--model", default=None)

    rn = sub.add_parser("run", help="run a packet payload through the DIY worker")
    rn.add_argument("--payload", required=True)
    rn.add_argument("--output", required=True)
    rn.add_argument("--packet-id", dest="packet_id", default="")
    rn.add_argument("--model", default=None)
    rn.add_argument("--system", default=None)
    rn.add_argument("--prompt", default=None)
    rn.add_argument("--message", default=None)
    rn.add_argument("--force", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    handlers = {
        "schema": cmd_schema,
        "show": cmd_show,
        "set": cmd_set,
        "clear": cmd_clear,
        "test": cmd_test,
        "models": cmd_models,
        "chat": cmd_chat,
        "run": cmd_run,
    }
    try:
        return handlers[args.cmd](args)
    except SystemExit as exc:
        # argparse / our explicit exits
        code = exc.code
        if code is None:
            return 0
        if isinstance(code, int):
            return code
        eprint(str(code))
        return 1
    except ValueError as exc:
        eprint(str(exc))
        return 1
    except RuntimeError as exc:
        eprint(str(exc))
        return 2
    except OSError as exc:
        eprint(str(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
