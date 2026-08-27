# Model-aware multi-agent orchestration

- The primary agent is the architect, planner, reviewer, and final integrator. Keep complex reasoning, cross-cutting decisions, conflict resolution, and final acceptance in the primary thread.
- Only the primary agent may delegate. Subagents must not spawn additional agents.
- For change, build, or fix requests, inspect the repository first and split suitable work into at most three independent, bounded work packages. Delegate only when parallel work materially improves speed or quality.
- Route delegated work by task shape instead of using one model for every package:
  - Use `explorer` for focused, read-only codebase questions.
  - Use `worker` with `gpt-5.6-luna` at `medium` effort for routine, low-risk implementation, focused tests, and log analysis.
  - Use `worker` with `gpt-5.6-terra` at `high` effort for bounded implementation or review that requires substantial judgment.
  - Keep architecture, cross-cutting changes, security/data/release-critical decisions, conflict resolution, and final acceptance in the primary `gpt-5.6-sol` thread. If a genuinely independent critical-review lane is useful, use `worker` with `gpt-5.6-sol` at `xhigh` effort.
- Do not use `luna_worker` by default: that preset is fixed to `gpt-5.6-luna` at `max`. Reserve it, and `max` effort generally, for the hardest quality-first packages where the extra reasoning is justified by the acceptance criteria.
- When selecting an explicit worker model or effort, pass only the minimum necessary context and use a bounded-history fork as required by the orchestration runtime.
- Every delegated package must state its goal, owned files or directories, forbidden scope, dependencies, acceptance criteria, and validation command.
- Never let two write-capable workers own overlapping files. Run dependent packages sequentially. Prefer parallelism for read-heavy exploration, independent modules, focused tests, and log analysis.
- All agents must preserve the dirty worktree and unrelated user changes. Do not commit, push, merge, reset, clean, delete unrelated files, or rewrite history unless the user explicitly authorizes that exact action.
- The primary agent waits for all requested workers, inspects their results and the combined diff, resolves inconsistencies, and runs or assigns one final verification lane before reporting completion.
