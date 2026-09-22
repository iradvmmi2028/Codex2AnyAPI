# Binding, transport, and failure rules

## Fixed model roles

| Role | Model | Reasoning |
|---|---|---|
| Orchestrator | `gpt-6-astra` | `high` |
| Worker (default) | `gpt-5.6-luna` | `max` |
| Worker (astra-Diy) | custom OpenAI-compatible model | provider-defined |

The default worker pair is pinned by the launcher. When astra-Diy is enabled with `replace_luna`, dispatch defaults to transport `diy-openai` and the configured custom model — Astra remains the tower. `doctor` reports configuration but does not edit `config.toml`.

## Integrity and state

Every execution payload and result has a SHA-256 binding. The launcher hashes the exact dispatched bytes and refuses mismatches.

State moves one way: `new → done → ingested → summarized`.

- Exit `0`: success
- Exit `1`: usage or validation error
- Exit `2`: runtime or corrupt packet error
- Exit `3`: hash mismatch **or incomplete DIY config**

Never alter a dispatched packet or move state out of order.

## Route verification

For `local-worker`, a known-answer round trip through `codex exec --model gpt-5.6-luna -c model_reasoning_effort="max"` verifies the route. Exact model-name self-identification is not required because GPT-5.6 tiers may identify their GPT-5 base.

For `diy-openai`, run `diy-test` (GET /models) and `diy-models`. Nonzero exit is a hard stop — never silent fallback to Luna.

A `.cmd` shim is not by itself a reason to fall back; the launcher resolves the native executable. Use `web-manual` only when no local worker can be resolved and the user explicitly approves.

## Failures

On failure, report the command, exit code, and journal evidence. Do not retry silently. If a web-dispatched packet has no result, create a new packet for local dispatch rather than reusing it.

The state directory lives beside the launcher. `ASTRA_LUNA_STATE_DIR`, `CODEX_HOME`, `ASTRA_DIY_CONFIG`, and `ASTRA_DIY_API_KEY` are supported for isolated tests and DIY providers.
