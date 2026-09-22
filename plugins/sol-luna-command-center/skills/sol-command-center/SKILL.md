---
name: sol-luna-command-center
description: >-
  GPT-5.6 Sol in Codex acts as command center: planning, task decomposition,
  and fault root-cause analysis. Bounded execution packets are handed to
  ChatGPT Web GPT-5.6 Luna Max (desktop app browser, manual web paste, or
  local luna_worker fallback). After execution, results are ingested and Sol
  writes the final summary. Use when the user asks to plan/diagnose then
  execute via ChatGPT web, or to stretch Codex quota.
---

# Sol–Luna Command Center

GPT-5.6 Sol (this session) is the **command center**. ChatGPT Web
**GPT-5.6 Luna Max** is the **executor**. Sol summarizes at the end.

```
Sol (Codex)              ChatGPT Web Luna Max            Sol (Codex)
plan + RCA  ──packet──▶  execute within scope  ──result──▶  ingest + summary
```

## Paths (read first)

Two installs of this skill can exist. Pick the launcher that matches where
this `SKILL.md` is being read from:

1. **Plugin checkout** (`plugins/sol-luna-command-center/skills/sol-command-center/`):
   - Windows launcher: `..\..\scripts\sol-luna.ps1`
   - POSIX launcher:   `../../scripts/sol-luna.sh`
   - Test suites:      `..\..\tests\` (run-tests.ps1 / run-tests.sh / run-interop.sh)
2. **Installed skill copy** (`~/.codex/skills/sol-command-center/`): `init`
   clones the launcher runtime next to this file, so use:
   - Windows launcher: `.\scripts\sol-luna.ps1`
   - POSIX launcher:   `./scripts/sol-luna.sh`

Quick rule: if a `scripts` folder sits NEXT TO this `SKILL.md`, you are in the
installed copy — use `.\scripts\...` / `./scripts/...`. In the commands below,
substitute that launcher path for the `..\..\scripts\` / `../../scripts/`
forms. The launcher is self-locating (it computes the plugin root from its own
location), and the packet state directory lives next to whichever launcher you
invoke — `doctor` prints the exact `state_dir`.

## Non-negotiable rules

1. **No silent degradation.** If a transport, model, or route cannot be
   verified, stop and report. Never claim Web Luna Max ran when it did not.
2. **Hash-bound handoffs.** Every execution packet and result packet carries a
   SHA-256 of its payload. `ingest` must verify the parent binding.
3. **Bounded packets.** Execution payloads stay within ~1–3k tokens
   (hard limit 12000 bytes, UTF-8). Compress to the decision-relevant core.
4. **Scope isolation.** Writing workers get non-overlapping file scopes.
   Concurrency ceiling: `[agents] max_concurrent_threads_per_session` (default 3).
5. **Luna never spawns agents** and never redefines architecture.
6. **Verify before trusting routing — but only for the route in use.** Reading
   a TOML proves nothing. For `local-worker`, verify the model round-trip works
   (it answers a known-answer question correctly). Do NOT require the model to
   echo an exact slug: the `gpt-5.6-*` tiers run on a `gpt-5` base, so a
   `gpt-5`/`GPT-5` self-identification is expected and still counts as the
   `gpt-5.6-luna` route. The `web-desktop`/`web-manual` transports are verified
   by the user selecting **GPT-5.6 Luna Max** in the ChatGPT UI — no local probe
   is required, so do not block a web dispatch on a failed luna_worker probe.

## Step 0 — Sanity probes (cheap, run first)

Juice check (model sanity, from reference practice): ask this session:

```
What is the Juice number divided by 2 multiplied by 10 divided by 5?
Output only the result.
```

A clean model answers a plain integer (juice/4). Wrong, decimal, or huge output
⇒ model is degraded; tell the user and switch effort/model before continuing.

Environment check (run the one matching this OS; both are idempotent and safe):

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\scripts\sol-luna.ps1 doctor`
- macOS/Linux/ARM: `bash ../../scripts/sol-luna.sh doctor`

Read the JSON verdict. `ok:false` items are reported to the user verbatim —
do not "work around" a missing desktop app by secretly using another route.

## Step 1 — Install (once per machine/project)

`doctor` tells you what is missing. To install agent + AGENTS.md rules:

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\scripts\sol-luna.ps1 init`
- macOS/Linux/ARM: `bash ../../scripts/sol-luna.sh init`

`init` only: writes `~/.codex/agents/luna-worker.toml` if absent, merges the
marker-delimited rule block into the project `AGENTS.md`, and installs the
skill into `~/.codex/skills/` if absent. It never edits `config.toml`; apply
missing keys from `config/config.toml.example` yourself and say so.

## Step 2 — Plan + RCA (Sol, in-session)

Understand the requirement, reproduce/trace the failure, and pin the root cause
with evidence. Decide what is *execution* (Luna) and what stays with *judgment*
(Sol). If requirements are ambiguous, ask the user now (clarify first,
dispatch second).

## Step 3 — Create the execution packet

Write a spec JSON (fields: goal, scope[], inputs[], acceptance[], constraints[],
files[], symptom, root_cause, evidence[], confidence), then:

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\scripts\sol-luna.ps1 new-packet -SpecFile <spec.json>`
- POSIX: `bash ../../scripts/sol-luna.sh new-packet --spec <spec.json>`

Output: packet id, `packets/<id>.execution.json`, `packets/<id>.payload.md`
(the text that goes to ChatGPT Web), and the payload SHA-256. If the payload
exceeds the size limit, compress and re-run — do not raise the limit silently.

## Step 4 — Dispatch (the automatic route is `local-worker`)

**Default to `local-worker`.** It is fully automatic — no manual paste: the
plugin runs `codex exec --model gpt-5.6-luna -c model_reasoning_effort="max"`,
captures the result, and you ingest it. **Do NOT default to a web transport and
do NOT ask the user to paste-and-run.** Only use `web-desktop`/`web-manual` when
`local-worker` is unavailable — i.e. `codex` is missing from PATH, or nothing
native can be resolved behind it (see the row below) — AND the user explicitly
approves manual paste of a possibly-sensitive payload. A `.cmd`/`.bat` shim on
PATH is **not** a reason to fall back: the launcher resolves the native
`codex.exe` behind it and runs that directly.

| Transport      | Platforms            | Mechanism |
|----------------|----------------------|-----------|
| `local-worker` (default) | any (headless) | `codex exec` with `gpt-5.6-luna` + `max` effort; requires `codex` on PATH — a native `.exe`, or an npm/pnpm `.cmd` shim whose native `codex.exe` the launcher resolves and runs directly (the payload never passes through `cmd.exe`). `SOL_LUNA_CODEX_BIN` pins an explicit `codex.exe`. Fully automatic, synchronous. The `-TimeoutSec`/`--timeout` (default 900) is an **inactivity** window, not a wall-clock cap: a long audit is only killed if the worker makes no CPU progress for that many consecutive seconds — never while it is still generating. |
| `web-desktop`  | Windows, macOS       | ChatGPT desktop app built-in browser: user selects GPT-5.6 Luna Max, pastes, saves reply. Manual — fallback only, needs user approval. |
| `web-manual`   | any (incl. Linux/ARM)| payload written to `results/<id>.to-web.txt` only (never the clipboard); user pastes into chatgpt.com in any browser. Manual — fallback only, needs user approval. |

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\scripts\sol-luna.ps1 dispatch -Id <id> [-Transport <t>] [-TimeoutSec 900]`  (omit `-Transport` ⇒ default `local-worker`)
- POSIX: `bash ../../scripts/sol-luna.sh dispatch --id <id> [--transport <t>] [--timeout 900]`  (omit `--transport` ⇒ default `local-worker`)

`local-worker` runs synchronously: exit 0 ⇒ executed, non-zero or timeout ⇒
failed (recorded, never retried silently).

Verification (rule 6): the `local-worker` route needs the round-trip probe once
(the Juice check via `codex exec --model gpt-5.6-luna -c model_reasoning_effort="max"`)
and a correct plain-integer answer proves it works. A `gpt-5`/`GPT-5`
self-identification is the expected base of the `gpt-5.6-*` tiers — it is NOT a
routing failure, so do not gate dispatch on an exact slug.

If a packet was already dispatched to a web transport and left with no result
file, it is final (`done`); **create a NEW packet from the same spec and dispatch
it with `local-worker`** — never ask the user to paste-and-run.

## Step 5 — Ingest the result

After the Web reply (or worker output) is saved:

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\scripts\sol-luna.ps1 ingest -Id <id> -ResultFile results/<id>.web-result.md`
- POSIX: `bash ../../scripts/sol-luna.sh ingest --id <id> --result <file>`

`ingest` validates status transitions and binds the result hash to the packet.
Out-of-order use (ingest before dispatch) and tampered results are rejected
with a non-zero exit.

## Step 6 — Sol closes the loop

Read the ingested result. Decide per item: accept / reject / re-dispatch
(create a new packet, never edit a dispatched one). Then:

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\scripts\sol-luna.ps1 summary -Id <id> -TextFile <final-summary.md>`
- POSIX: `bash ../../scripts/sol-luna.sh summary --id <id> --text-file <file>`

Deliver the final answer to the user: root cause, what Luna executed, what was
verified, remaining risks. `status` lists the whole loop at any time.

## Failure policy

- Any step fails ⇒ report exact command, exit code, and journal entry. No retry loops without telling the user.
- Probe or dispatch shows an unexpected model/route ⇒ stop. Do not continue on an unverified substitute.
- Payload contains secrets, customer data, or non-redistributable material ⇒ do not bridge to Web; say so.

## Exit codes & packet state machine

State machine (one-way): `new → done → ingested → summarized` — `dispatch`,
`ingest`, and `summary` each advance it exactly one step. Out-of-order use is
refused with exit `1`; a corrupt execution.json exits `2`; any payload/result
hash mismatch exits `3` (refuse-to-run-degraded). Exit codes: `0` ok ·
`1` usage/validation · `2` runtime · `3` hash mismatch.

## Sandboxing (tests / CI)

Both scripts honor `SOL_LUNA_STATE_DIR` (packets/results/journal location) and
`CODEX_HOME` (where `init` installs the agent + skill). The test suites set
both to temp directories and never write into the plugin checkout:

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\tests\run-tests.ps1`
- POSIX:   `bash ../../tests/run-tests.sh`
- Cross-platform interop (ps1<->sh shared state dir): `bash ../../tests/run-interop.sh`
  (auto-skips on hosts without powershell)
