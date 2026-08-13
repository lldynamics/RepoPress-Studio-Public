# Sol and Luna orchestration

- The primary agent is the architect, planner, reviewer, and final integrator. Keep complex reasoning, cross-cutting decisions, conflict resolution, and final acceptance in the primary thread.
- Only the primary agent may delegate. Subagents must not spawn additional agents.
- For change, build, or fix requests, inspect the repository first and split suitable work into at most three independent, bounded work packages. Use `luna_worker` for execution when parallel delegation materially improves speed or quality.
- Every delegated package must state its goal, owned files or directories, forbidden scope, dependencies, acceptance criteria, and validation command.
- Never let two write-capable workers own overlapping files. Run dependent packages sequentially. Prefer parallelism for read-heavy exploration, independent modules, focused tests, and log analysis.
- All agents must preserve the dirty worktree and unrelated user changes. Do not commit, push, merge, reset, clean, delete unrelated files, or rewrite history unless the user explicitly authorizes that exact action.
- The primary agent waits for all requested workers, inspects their results and the combined diff, resolves inconsistencies, and runs or assigns one final verification lane before reporting completion.
