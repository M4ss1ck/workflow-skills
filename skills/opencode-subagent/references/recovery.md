# Recovering supervision, state and retention

## Recovering supervision

Nothing important lives only in your conversation. A fresh supervisor with no context can pick up any Task:

```bash
opencode-delegate recover --json          # reconcile crashed/interrupted attempts first
opencode-delegate list --active --json    # what is still open
opencode-delegate show TASK               # the whole story, in order
opencode-delegate logs TASK attempt_002 --stream request   # exactly what was asked
```

A Task that finished and never got a decision stays in `awaiting_supervisor` indefinitely. `start`, `run`, `status` and `list` print a one-line note on stderr when this worktree has any, so a delegation you launched and walked away from surfaces on your next command instead of on nobody's.

`recover` is safe to run at any time. It finds attempts whose runner and provider processes died without writing a result, records them as `interrupted`, folds in results that were written but never applied, and leaves everything else alone. A live provider remains `running` even if its detached runner disappeared. It never invents an outcome and never rewrites history.

A detached attempt that finishes *after* you moved on cannot change the Task: it is recorded as `attempt_stale` and its own result is flagged `authoritative: false`.

## State and retention

State lives under `~/.local/state/workflow-skills/subagents/task_<id>/`:

```text
task.json          current state, replaced atomically
events.jsonl       append-only history (task_created, attempt_started, session_discovered,
                   worker_done, worker_blocked, attempt_incomplete/timeout/failed/cancelled,
                   attempt_stale, verification_started/passed/failed, supervisor_decision,
                   task_accepted/rejected/cancelled, supervisor_takeover, task_reconciled)
verifications/     ver_NNN.json + captured stdout/stderr
attempts/attempt_NNN/
  request.md       the exact text sent to the worker
  meta.json (including the exact `opencode_version`) result.json worker-report.txt changed-files.txt
  pid process.json provider.pid provider-process.json
  raw.jsonl stderr.log provider-progress.json provider-baseline.json
  provider-errors.log  (only when the OpenCode stream reported errors)
```

On Linux, each persisted process identity includes the kernel boot ID and `/proc` start time as well as the PID, so a reboot or reused numeric PID is not mistaken for the old process. Other platforms fall back to `kill -0` liveness.

`task.json` is authoritative for current state. `events.jsonl` is the append-only audit history, not a state-replay log. While holding the per-Task lock, a command atomically replaces `task.json` first and then appends the corresponding event. A crash in that narrow gap can leave current state newer than the history; `recover` reconciles attempt completion idempotently without duplicating terminal events. Event sequence numbers are unique and gap-free for the events that were durably appended.

Jobs are detached and survive your session. Retention is configurable in `subagents.conf`: terminal Task history is kept for `OPENCODE_SUBAGENT_RETENTION_DAYS` (default 90), while its bulky provider streams (`raw.jsonl`, `provider-progress.json`, `provider-baseline.json`, git snapshots) are dropped after `OPENCODE_SUBAGENT_RAW_RETENTION_DAYS` (default 7). Active and unresolved Tasks are never pruned. Pruning runs on launch and does not inspect or remove sibling Claude/Codex state.
