<!-- astra-luna:begin (managed by astra-luna-command-center; do not remove markers) -->
## Astra + Luna command-center routing

- GPT-6 Astra (this Codex session) owns requirements, decomposition, root-cause
  analysis, architecture, integration, final review, and the final answer.
- Execution of bounded, independently verifiable subtasks is handed to the
  `gpt-5.6-luna` worker fleet (reasoning effort `max`) via astra-luna-command-center
  execution packets (`scripts/astra-luna.ps1` on Windows, `scripts/astra-luna.sh`
  on macOS/Linux/ARM). When the local worker route is unavailable, manual web
  paste is the only fallback; never silently substitute another model.
- Keep trivial or tightly coupled work in Astra. Read-only probes may run in parallel.
- File-writing tasks must use non-overlapping file scopes (or separate worktrees);
  otherwise run them sequentially.
- A Luna worker must not spawn another agent, redefine architecture, make
  destructive changes, or modify unrelated files.
- Every handoff packet must include goal, scope, inputs, acceptance criteria,
  and file boundaries. Every result packet is hash-bound (SHA-256) to its
  execution packet before Astra accepts it.
- Astra waits for every worker, inspects each result and diff, re-dispatches
  failures when useful, and performs the final integration, acceptance, and
  summary. No silent degradation: if a transport or route cannot be verified,
  stop and report instead of continuing with an unverified substitute.
<!-- astra-luna:end -->

