# astra-luna-command-center — Installation

> GPT-6 Astra command center: build bounded execution packets, dispatch them
> to the `gpt-5.6-luna` worker fleet (reasoning effort `max`; local
> `astra_*` role agents or manual web paste), ingest the hash-bound result,
> and write the summary. Packets move one-way through
> `new → done → ingested → summarized`.

This package is a **standalone Codex plugin marketplace**. Unzipping gives you a
repo root that Codex can register directly — no copying files by hand.

```
astra-luna-command-center-marketplace/      <- the repo / marketplace root
├── .agents/plugins/marketplace.json        <- Codex marketplace index
├── INSTALL.md                              <- this file
└── plugins/astra-luna-command-center/      <- the plugin (manifest + scripts)
```

This plugin is an independent successor to `sol-luna-command-center`; it
installs alongside it and never touches the old plugin's files.

---

## 1. Install from the Codex marketplace (recommended)

1. Extract the zip anywhere you like.
2. Open the **Codex** desktop app → **插件 (Plugins)** → **添加 (Add)** →
   **添加插件市场 (Add plugin marketplace)**.
3. Point it at the **extracted `astra-luna-command-center-marketplace` folder**
   (the one that contains `.agents/plugins/marketplace.json`).
4. `astra-luna-command-center` appears in the list → click **安装 (Install)**.
5. Restart / reload the session so the skill is picked up.

> Codex resolves the plugin from the marketplace root, so the registration is
> fully local — no network, no account, no OpenAI marketplace required.

## 2. Alternate install: `init` (role agents + skill + rules)

The marketplace install only registers the plugin package. The five
`astra_*` **role agents** live in `~/.codex/agents/` and are provisioned by
the plugin's own `init` command — this also merges the routing rules into
`AGENTS.md` and copies the skill into `~/.codex/skills/`. It never edits
`config.toml` and never overwrites files that already exist (including files
installed by the old sol-luna plugin).

```bash
# Windows
powershell -File plugins/astra-luna-command-center/scripts/astra-luna.ps1 init

# POSIX / macOS / Linux / ARM
bash plugins/astra-luna-command-center/scripts/astra-luna.sh init
```

Run from the directory that holds `plugins/` (the repo root). The `init` is
idempotent — safe to run repeatedly.

Then apply the suggested harness config yourself (the plugin never edits
`config.toml`): merge the commented lines of
`config/config.toml.example` into `~/.codex/config.toml` —

```
model = "gpt-6-astra"
model_reasoning_effort = "high"
```

Do NOT add the upstream article's scalar `[agents]` block: on the
Codex-GPT56 fork the `[agents]` table is a role-name -> AgentRoleToml map,
and scalar keys there break config reload. The luna worker fleet is
provisioned as files instead — `init` installs `~/.codex/agents/astra-*.toml`
(explorer / worker / tester / reviewer / researcher, each pinned to
`gpt-5.6-luna` at `max` effort), and every local-worker dispatch passes
`--model gpt-5.6-luna -c model_reasoning_effort="max"` explicitly.

## 3. Verify

```bash
# Windows
powershell -File plugins/astra-luna-command-center/scripts/astra-luna.ps1 doctor

# POSIX
bash plugins/astra-luna-command-center/scripts/astra-luna.sh doctor
```

A healthy verdict reports exit `0` with `agent_toml: true`,
`codex_cli_config: true` and `local_worker: true`, and `astra_model:
gpt-6-astra` / `luna_model: gpt-5.6-luna` / `luna_effort: max`. If the agents
are missing, `doctor` prints the exact copy-pasteable `init` command to run.

If `codex_cli_config` is `false` (exit `2`), the codex CLI cannot load
`~/.codex/config.toml` at all — every `codex exec` dispatch dies with exit `1`
(e.g. `invalid type: map, expected a boolean`) before reaching any model,
even though the desktop app itself keeps working. The usual cause is a nested
table inside `[features]` (e.g. `[features.context_management]`); `doctor`
prints the offending lines — flatten or remove them (keep a backup), then
re-run `doctor`. `local_worker: false` additionally means `codex` itself was
not found on PATH (`codex_cli: false`) — in that case use `web-manual`.

## 4. Quick start

```bash
# 1. write a spec (see examples/fix-http-reset.spec.json)
# 2. build the packet
bash plugins/astra-luna-command-center/scripts/astra-luna.sh new-packet --spec examples/fix-http-reset.spec.json
# 3. dispatch (automatic local worker, or manual web paste)
bash plugins/astra-luna-command-center/scripts/astra-luna.sh dispatch --id <id> --transport local-worker
# 4. for web-manual: paste the staged payload, then save Luna's reply to results/<id>.web-result.md
bash plugins/astra-luna-command-center/scripts/astra-luna.sh ingest  --id <id> --result results/<id>.web-result.md
bash plugins/astra-luna-command-center/scripts/astra-luna.sh summary --id <id> --text-file <final-summary.md>
bash plugins/astra-luna-command-center/scripts/astra-luna.sh status
```

Windows: replace `bash ... astra-luna.sh` with
`powershell -File .../astra-luna.ps1` and `--id/--transport/--spec` with
`-Id/-Transport/-SpecFile`.

## 4b. astra-Diy (custom OpenAI-compatible worker)

Optional. Replaces **only** the `gpt-5.6-luna` worker model; GPT-6 Astra still
plans, reviews, and summarizes.

```powershell
# Windows settings dialog (Base URL / API Key / Model textboxes + test + model list)
powershell -File plugins/astra-luna-command-center/scripts/astra-luna.ps1 diy-settings

# CLI
powershell -File plugins/astra-luna-command-center/scripts/astra-luna.ps1 diy-set -BaseUrl "http://127.0.0.1:11434/v1" -ApiKey "sk-..." -Model "my-model" -Enabled true -ReplaceLuna true
powershell -File plugins/astra-luna-command-center/scripts/astra-luna.ps1 diy-test
powershell -File plugins/astra-luna-command-center/scripts/astra-luna.ps1 diy-models
powershell -File plugins/astra-luna-command-center/scripts/astra-luna.ps1 diy-show
```

In Codex, invoke the command/skill **`/astra-Diy`** (see `commands/astra-Diy.md`).
Provider must speak OpenAI API shape (`/v1/models`, `/v1/chat/completions`).
Incomplete config or failed connectivity exits nonzero — never a silent Luna fallback.

## 5. Requirements & notes

- **Local worker** needs a native `codex` CLI on PATH. A `.cmd`/`.bat` shim
  (the usual npm/pnpm install) is accepted too: the plugin resolves the native
  `codex.exe` the shim launches and calls that directly, so the payload never
  passes through `cmd.exe`. If `codex` is missing, or nothing native can be
  resolved behind a shim, `doctor` reports it and you should use `web-manual`.
  Set `ASTRA_LUNA_CODEX_BIN` to pin an explicit `codex.exe`.
  `web-manual` never touches the clipboard.
- Workers are pinned to **`gpt-5.6-luna`** with
  **`model_reasoning_effort = "max"`** — custom model names from the
  `Codex-GPT56` fork. On a stock OpenAI Codex install, `local-worker` will
  **not** have this model; use `web-manual` there. The orchestrator
  (`gpt-6-astra`, `high`) is configured in `config.toml` per the Astra/Luna
  article.
- Packet payloads are hard-capped at **12 000 bytes** (UTF-8). Oversized specs
  are refused, never truncated.
- The state directory (`packets/`, `results/`, `journal.jsonl`) defaults to
  `<plugin>/.astra-luna-state` and is git-ignored. Redirect it with
  `ASTRA_LUNA_STATE_DIR` (CI / sandbox). On POSIX it is created with
  owner-only permissions (`umask 077` + `chmod 700`).
- Exit codes: `0` ok · `1` usage/validation · `2` runtime · `3` hash mismatch.

## License

MIT — see `LICENSE`.
