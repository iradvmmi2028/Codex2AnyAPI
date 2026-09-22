---
name: astra-diy
description: Configure and run the astra-Diy OpenAI-compatible custom worker that replaces gpt-5.6-luna under GPT-6 Astra. Use when the user mentions astra-Diy, DIY worker, custom model, local OpenAI-compatible API, base_url/API key setup, model list, or connection test.
---

# astra-diy — OpenAI-compatible custom worker

**Astra stays the control tower.** DIY only replaces the worker model that executes bounded packets (otherwise `gpt-5.6-luna` + max). Results return as Markdown/source-edit reports; Astra always reviews before summary.

## Providers

### OpenAI-compatible
- `GET /models` + `POST /chat/completions`
- Base URL + Bearer API Key + model id

### WeChat Chatbot Open Platform（微信对话开放平台）
- Auto-selected when Base URL is `chatapi.weixin.qq.com` / `openaiapi.weixin.qq.com` or `provider=wechat-chatapi`
- **Not** standard OpenAI: needs **APPID + Token + EncodingAESKey** from [chatbot.weixin.qq.com](https://chatbot.weixin.qq.com) (开放 API 申请通过后)
- Adapter: `scripts/wechat-chatapi.py`
  - `POST /v2/token`（X-APPID + sign）
  - `POST /v2/bot/query`（X-OPENAI-TOKEN + AES-CBC body）
  - `sign = md5(Token + timestamp + nonce + md5(body))`
- Model field = bot display name（平台无 OpenAI 模型目录）
- Only a single opaque key usually fails；请用 CLI `diy-test` 验证

```powershell
powershell -File ...\astra-luna.ps1 diy-set -Provider wechat-chatapi `
  -BaseUrl "https://openaiapi.weixin.qq.com" `
  -AppId "你的APPID" -ApiKey "你的Token" -AesKey "你的EncodingAESKey" `
  -Model "wechat-bot" -Enabled true -ReplaceLuna true
powershell -File ...\astra-luna.ps1 diy-test
```

## Setup surface

Settings fields (also used by the Windows dialog / plugin docs):

1. **Base URL** — OpenAI-compatible endpoint (`http://127.0.0.1:11434/v1`, `https://api.example.com/v1`)
2. **API Key** — Bearer token (env `ASTRA_DIY_API_KEY` overrides stored key)
3. **Model** — custom model id from the provider (replaces gpt-5.6-luna)
4. **Enable DIY** / **Replace Luna** — gate diy-openai as the default dispatch route

Config file: `<state_dir>/diy.json` (override `ASTRA_DIY_CONFIG`).  
Client: `scripts/openai-diy.py`. Settings GUI: `scripts/diy-settings.ps1` (Windows textboxes).

## Launcher commands

```text
diy-set | diy-show | diy-clear | diy-test | diy-models | diy-settings | diy-schema
```

Windows example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-settings
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-test
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-models
```

## Dispatch

- With DIY enabled + replace_luna, `dispatch` defaults to transport **`diy-openai`**.
- Explicit `-Transport local-worker` still pins gpt-5.6-luna (fallback/tests).
- Failure modes are explicit (exit 1/2/3). Never silently switch models.

## Astra review loop

1. `new-packet` (Astra writes the spec).
2. `dispatch` → diy worker returns `results/<id>.result.md`.
3. Astra checks acceptance criteria / code diffs.
4. Approve → `summary`; reject → new packet (never edit a dispatched packet).

## Safety

- Only OpenAI API-shaped providers (`/v1/models`, `/v1/chat/completions`).
- Do not echo full API keys.
- Payload hash binding still applies.
- DIY does not grant the worker permission to spawn agents or redefine architecture.

## When to use this skill vs the command center skill

- Use **astra-diy** when configuring providers, custom model ids, connection tests, or DIY routing.
- Use **astra-command-center** for the general packet/state-machine workflow.
