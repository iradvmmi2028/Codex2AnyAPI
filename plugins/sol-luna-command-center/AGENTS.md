<!-- sol-luna:begin (managed by sol-luna-command-center; do not remove markers) -->
## Sol + Luna Max command-center routing

- GPT-5.6 Sol (this Codex session) owns requirements, decomposition, root-cause
  analysis, architecture, integration, final review, and the final answer.
- Execution of bounded, independently verifiable subtasks is handed to ChatGPT
  Web GPT-5.6 Luna Max via sol-luna-command-center execution packets
  (`scripts/sol-luna.ps1` on Windows, `scripts/sol-luna.sh` on macOS/Linux/ARM).
  When Web handoff is unavailable, the local `luna_worker` agent is the only
  fallback; never silently substitute another model.
- Keep trivial or tightly coupled work in Sol. Read-only probes may run in parallel.
- File-writing tasks must use non-overlapping file scopes (or separate worktrees);
  otherwise run them sequentially.
- A Luna worker must not spawn another agent, redefine architecture, make
  destructive changes, or modify unrelated files.
- Every handoff packet must include goal, scope, inputs, acceptance criteria,
  and file boundaries. Every result packet is hash-bound (SHA-256) to its
  execution packet before Sol accepts it.
- Sol waits for every worker, inspects each result and diff, re-dispatches
  failures when useful, and performs the final integration, acceptance, and
  summary. No silent degradation: if a transport or route cannot be verified,
  stop and report instead of continuing with an unverified substitute.
<!-- sol-luna:end -->
