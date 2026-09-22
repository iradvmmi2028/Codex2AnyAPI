---
name: astra-command-center
description: Use GPT-6 Astra to plan or diagnose a complex task, then hand bounded execution to a worker (gpt-5.6-luna or astra-Diy custom model). Use only when the user requests Astra–Luna orchestration or explicitly wants cheaper/custom worker execution.
---

# Astra–Luna Command Center

GPT-6 Astra owns architecture, decomposition, root-cause judgment, and final acceptance. The worker executes bounded work: default `gpt-5.6-luna` at `max` reasoning effort, or an OpenAI-compatible custom model when astra-Diy is enabled (`/astra-Diy`).

## Route only what the task needs

- For a new handoff, read [references/workflow.md](references/workflow.md).
- For transport failures, integrity checks, model binding, or state-machine questions, read [references/safety.md](references/safety.md).
- For custom OpenAI-compatible worker setup (base_url / API key / model / connection test), use the sibling skill `astra-diy` or command `/astra-Diy`.
- Run `doctor` only on first use, after configuration changes, or when routing fails. A recent successful check is reusable.
- Do not load both references unless the task genuinely needs both.

## Core rules

1. Keep judgment with Astra and delegate only concrete execution.
2. Make each worker packet self-contained and decision-relevant; target 400–1,200 tokens and never exceed 12,000 UTF-8 bytes.
3. Give writing workers non-overlapping scopes. Luna/DIY workers never spawn agents or change architecture.
4. Never claim a worker or route ran unless verified. Preserve SHA-256 packet/result binding.
5. Default to `local-worker` (gpt-5.6-luna) unless DIY `replace_luna` is ready — then default dispatch is `diy-openai`. Use a web route only when local execution is unavailable and the user approves sending the payload.
6. Accept, reject, or re-dispatch worker output; Astra always closes the loop.

Launcher paths are resolved by location: installed copies use `scripts\astra-luna.ps1`; plugin checkouts use `..\..\scripts\astra-luna.ps1`.
