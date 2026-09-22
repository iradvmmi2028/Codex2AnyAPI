---
description: Configure or use the astra-Diy OpenAI-compatible worker that replaces gpt-5.6-luna. Use when the user wants a custom/local model, custom base_url + API key, model list/connection test, or /astra-Diy.
---

# /astra-Diy — Custom OpenAI-compatible worker

GPT-6 Astra remains the **control tower** (plan, packet, review, summary).  
astra-Diy only **replaces the worker model** (`gpt-5.6-luna` + max) with a user-supplied OpenAI-compatible API (local Ollama/LM Studio/vLLM, or any remote provider that speaks the OpenAI API shape).

```
GPT-6 Astra (tower) --packet--> diy-openai (custom model) --result.md--> Astra review/summary
```

## Preflight (launcher)

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>\scripts\astra-luna.ps1 diy-show
```

POSIX:

```bash
bash <plugin>/scripts/astra-luna.sh diy-show
```

Launcher paths: installed skill uses `scripts\astra-luna.ps1`; plugin checkout uses `..\..\scripts\astra-luna.ps1`.

## Settings fields (textboxes / CLI)

| Field | Required | Example | Notes |
|-------|----------|---------|-------|
| Base URL | yes | `http://127.0.0.1:11434/v1` | OpenAI-compatible root; `/v1` auto-appended if missing |
| API Key | yes | `sk-...` / provider token | Never echo the full key. Env `ASTRA_DIY_API_KEY` overrides |
| Model | yes | `qwen2.5-coder:32b` | Free-form custom model id (自定义编写模型) |
| Enable DIY | yes | `true` | Gates the diy-openai transport |
| Replace Luna | recommended | `true` | When true, default dispatch uses diy-openai instead of local-worker |

## Commands

### 1) Open the settings dialog (real textboxes)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-settings
```

Or headless / non-Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-set -BaseUrl "https://api.example.com/v1" -ApiKey "sk-..." -Model "my-model" -Enabled true -ReplaceLuna true
```

```bash
bash astra-luna.sh diy-set --base-url "https://api.example.com/v1" --api-key "sk-..." --model "my-model" --enabled true --replace-luna true
```

### 2) Connection test + model fetch

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-test
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-models
```

- `diy-test` → `GET {base}/models` with Bearer auth; exit 0 means reachable + accepted key.
- `diy-models` → lists provider model ids so the user can pick one for `diy-set -Model`.
- Nonzero exit is a **hard stop**. Do not silently fall back to gpt-5.6-luna.

### 3) Use DIY as the worker (Astra still reviews)

After `diy-show` reports `ready: true` and `replace_luna: true`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> new-packet -SpecFile <spec.json>
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> dispatch -Id <id>
# default transport is now diy-openai
# then Astra inspects results\<id>.result.md against acceptance
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> summary -Id <id> -TextFile <summary.md>
```

Force the old Luna route explicitly if needed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> dispatch -Id <id> -Transport local-worker
```

## Rules

1. **Astra never hands the tower over.** DIY workers execute bounded packets only.
2. **OpenAI API format only.** Providers must expose `/v1/models` and `/v1/chat/completions` (or a base that normalizes to that).
3. **No silent substitution.** Incomplete DIY config → exit 3; failed HTTP → exit 2; never auto-switch back to Luna.
4. **Hash binding unchanged.** Payload SHA-256 still gates dispatch; diy results are hash-recorded like other transports.
5. **Secrets.** Do not paste full API keys into chat summaries. Show only masked forms (`sk-***...xyz`).
6. **Custom model writing.** Users may set any model id the provider exposes (`diy-set -Model ...`) — this is the custom-model entry point; agent TOMLs are not rewritten.

## Verification checklist

- [ ] `diy-show` → `ready: true`, `worker_route` mentions diy-openai + model name
- [ ] `diy-test` → `ok: true`, HTTP 200
- [ ] `diy-models` lists the chosen model (or provider accepts free-form ids)
- [ ] A sample `dispatch` writes `results/<id>.result.md` with transport `diy-openai`
- [ ] Astra review + `summary` completed; journal shows `run-done` with the diy model

## Disable

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> diy-clear
```

Keeps base_url/model for convenience but disables DIY and wipes the stored API key. Default dispatch returns to `local-worker` / gpt-5.6-luna.
