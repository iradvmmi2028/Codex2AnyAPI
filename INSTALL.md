# sol-luna-command-center — Installation

> GPT-5.6 Sol command center: build bounded execution packets, dispatch them to
> ChatGPT Web GPT-5.6 Luna Max (or the local `luna_worker` agent), ingest the
> hash-bound result, and write the summary. Packets move one-way through
> `new → done → ingested → summarized`.

This package is a **standalone Codex plugin marketplace**. Unzipping gives you a
repo root that Codex can register directly — no copying files by hand.

```
sol-luna-command-center-marketplace/        <- the repo / marketplace root
├── .agents/plugins/marketplace.json        <- Codex marketplace index
├── INSTALL.md                              <- this file
└── plugins/sol-luna-command-center/        <- the plugin (manifest + scripts)
```

---

## 1. Install from the Codex marketplace (recommended)

1. Extract the zip anywhere you like.
2. Open the **Codex** desktop app → **插件 (Plugins)** → **添加 (Add)** →
   **添加插件市场 (Add plugin marketplace)**.
3. Point it at the **extracted `sol-luna-command-center-marketplace` folder**
   (the one that contains `.agents/plugins/marketplace.json`).
4. `sol-luna-command-center` appears in the list → click **安装 (Install)**.
5. Restart / reload the session so the skill is picked up.

> Codex resolves the plugin from the marketplace root, so the registration is
> fully local — no network, no account, no OpenAI marketplace required.

You can also register it from the CLI:

```bash
# POSIX / macOS / Linux / ARM
codex                    # enter interactive CLI
/plugins                 # then install from the local marketplace
```

## 2. Alternate install: `init` (agent + skill + rules)

The marketplace install only registers the plugin package. The `luna_worker`
**agent** lives in `~/.codex/agents/` and is provisioned by the plugin's own
`init` command — this also merges the routing rules into `AGENTS.md` and copies
the skill into `~/.codex/skills/`. It never edits `config.toml`.

```bash
# Windows
powershell -File plugins/sol-luna-command-center/scripts/sol-luna.ps1 init

# POSIX / macOS / Linux / ARM
bash plugins/sol-luna-command-center/scripts/sol-luna.sh init
```

Run from the directory that holds `plugins/` (the repo root). The `init` is
idempotent — safe to run repeatedly.

## 3. Verify

```bash
# Windows
powershell -File plugins/sol-luna-command-center/scripts/sol-luna.ps1 doctor

# POSIX
bash plugins/sol-luna-command-center/scripts/sol-luna.sh doctor
```

A healthy verdict reports exit `0` with `agent_toml: true` and
`local_worker: true`. If the agent is missing, `doctor` prints the exact
copy-pasteable `init` command to run.

## 4. Quick start

```bash
# 1. write a spec (see examples/fix-http-reset.spec.json)
# 2. build the packet
bash plugins/sol-luna-command-center/scripts/sol-luna.sh new-packet --spec examples/fix-http-reset.spec.json
# 3. dispatch (manual web paste, desktop app, or local worker)
bash plugins/sol-luna-command-center/scripts/sol-luna.sh dispatch --id <id> --transport web-manual
# 4. save Luna's reply to results/<id>.web-result.md, then ingest + summarize
bash plugins/sol-luna-command-center/scripts/sol-luna.sh ingest  --id <id> --result results/<id>.web-result.md
bash plugins/sol-luna-command-center/scripts/sol-luna.sh summary --id <id> --text-file <final-summary.md>
bash plugins/sol-luna-command-center/scripts/sol-luna.sh status
```

Windows: replace `bash ... sol-luna.sh` with
`powershell -File .../sol-luna.ps1` and `--id/--transport/--spec` with
`-Id/-Transport/-SpecFile`.

## 5. Requirements & notes

- **Local worker** needs a native `codex` CLI (`.exe`) on PATH plus
  `timeout`/`gtimeout` (macOS: `brew install coreutils`). If `codex` is
  missing, `doctor` reports it and you should use `web-manual`/`web-desktop`.
- The plugin pins **`gpt-5.6-luna`** with **`model_reasoning_effort = "max"`** —
  **custom model names** from the `Codex-GPT56` fork. On a stock OpenAI Codex
  install, `local-worker` will **not** have this model; use `web-manual` or
  `web-desktop` there. `web-*` transports never touch the clipboard.
- Packet payloads are hard-capped at **12 000 bytes** (UTF-8). Oversized specs
  are refused, never truncated.
- The state directory (`packets/`, `results/`, `journal.jsonl`) defaults to
  `<plugin>/.sol-luna-state` and is git-ignored. Redirect it with
  `SOL_LUNA_STATE_DIR` (CI / sandbox).
- Exit codes: `0` ok · `1` usage/validation · `2` runtime · `3` hash mismatch.

## License

MIT — see `LICENSE`.
