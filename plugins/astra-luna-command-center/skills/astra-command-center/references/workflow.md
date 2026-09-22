# Workflow

Use the Windows commands below. On macOS/Linux, use the sibling `astra-luna.sh` commands with equivalent flags.

## 1. Verify when needed

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> doctor
```

Stop if `codex_cli_config` is false or the selected route cannot be verified. Do not silently substitute another model or route.

## 2. Plan and create one bounded packet

Astra identifies the requirement and root cause, then writes a spec JSON containing only:

`goal`, `scope`, `inputs`, `acceptance`, `constraints`, `files`, `symptom`, `root_cause`, `evidence`, `confidence`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> new-packet -SpecFile <spec.json>
```

Prefer one packet for one independently verifiable outcome. Include paths and evidence, not conversation history or generic instructions.

## 3. Dispatch

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> dispatch -Id <id> -TimeoutSec 900
```

The default `local-worker` route pins `gpt-5.6-luna` with `max` reasoning. Dispatch is synchronous. Nonzero exit or inactivity timeout is a reported failure, not an invitation to retry silently.

Use `web-manual` only if local execution is unavailable and the user approves the payload transfer. Never send secrets, customer data, or non-redistributable material through a web bridge.

## 4. Ingest and decide

Local-worker results are ingested by the launcher. For an approved manual result:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> ingest -Id <id> -ResultFile <result.md>
```

Astra checks the result against acceptance criteria. If it is insufficient, create a new packet; never edit a dispatched packet.

## 5. Summarize

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <launcher> summary -Id <id> -TextFile <summary.md>
```

Report the root cause, executed work, verification, and only material remaining risk. Use `status [-Id <id>]` when state needs inspection.
