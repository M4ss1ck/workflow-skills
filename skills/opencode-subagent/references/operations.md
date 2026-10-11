# Operations and machine-readable output

Full command reference. `opencode-delegate help` prints the same commands.

## Commands

```bash
opencode-delegate start  [opts] "<task>"        # launch Attempt 1 detached
opencode-delegate run    [opts] "<task>"        # launch and block
opencode-delegate retry  TASK --reason R "<fix>"# next Attempt, same session by default
opencode-delegate resume SESSION "<fix>"        # next Attempt on the Task owning SESSION
opencode-delegate status TASK                   # state + liveness, no blocking
opencode-delegate wait   TASK [--poll-timeout SECS]
opencode-delegate wait   --any TASK [TASK...]    # one table for several Tasks
opencode-delegate verify TASK [--label L] -- CMD ARGS...
opencode-delegate decide TASK DECISION --reason R
opencode-delegate cancel TASK [--keep-task]     # stop the running Attempt
opencode-delegate list   [--active] [--limit N]
opencode-delegate show   TASK                   # task + attempts + verifications + history
opencode-delegate attempts TASK
opencode-delegate events TASK
opencode-delegate logs   TASK [ATTEMPT] [--stream report|request|raw|stderr|progress|result|meta|changed]
opencode-delegate recover [--reports-only]      # reconcile crashes and restore final reports from saved streams
opencode-delegate policy [off|explicit|auto]
opencode-delegate help                          # full command reference
opencode-delegate route show [PROPOSAL]         # a denied native call and how to record it
opencode-delegate route record --proposal P ... # record a routing decision
opencode-delegate route doctor                  # hooks, PATH command, runtime, policy
```

Decisions: `accept` · `retry` · `reject` · `cancel` · `take_over` · `continue_waiting`. `--reason` is required for `retry`, `reject` and `take_over` — the reason is the durable record of why.

`status` and `wait` render the worker's parsed report — its verification, question and concerns — rather than the raw text, and cap a fallback report that is really provider JSONL. `--full` prints it verbatim; `--json` is never truncated.

If a completed Task was saved as `no_report` while its final `STATUS:` block is present in `raw.jsonl`, run `recover --reports-only`. It restores the parsed worker result and appends a `result_recovered` event while preserving the supervisor decision and verification. The default `recover` also reconciles interrupted attempts. Recovery is idempotent and leaves an incomplete or ambiguous final stream as `no_report`.

Options: `--model provider/model`, `--cwd DIR`, `--resume SESSION_ID`, `--new-session`, `--reason TEXT`, `--label TEXT`, `--timeout SECS` (default 1800), `--poll-timeout SECS`, `--stall-seconds SECS` (default 300), `--no-stall-return`, `--reports-only` (with `recover`), `--full`, `--save-default`, `--json`.

Exit codes: `0` finished · `1` verification failed · `2` usage/config or verification-execution error · `3` still running · `4` incomplete turn, resume the session · `5` still running but stalled · `124` timeout · `127` missing or unsupported CLI (OpenCode older than 2.x) · `130` cancelled.

`verify TASK -- CMD ARGS...` execs the argv; `verify TASK "cmd | cmd"` runs a shell line when you need pipes or `&&`.

## Machine-readable output

Add `--json` to any operation. `status`/`wait`/`start`/`run` return the flat view:

```json
{
  "task_id": "task_20260813-101500-4821",
  "job_id": "task_20260813-101500-4821",
  "task_state": "awaiting_supervisor",
  "state": "completed",
  "attempt_id": "attempt_002",
  "attempt_count": 2,
  "outcome": {"transport": "finished", "worker": "blocked", "verification": "failed", "supervisor": "decision_required"},
  "failure_class": "worker_blocked",
  "recommended_action": "supervisor_decision",
  "session_id": "ses_abc",
  "model": "openrouter/some-cheap-model",
  "exit_code": 0,
  "cost_usd": 0.031,
  "changed_files": ["src/foo.ts"],
  "report": "STATUS: BLOCKED\n…",
  "liveness": null,
  "last_verification": {"id": "ver_001", "command": "pnpm test foo", "result": "failed", "exit_code": 1},
  "disposition": {"decision": "retry", "reason": "…"},
  "attempt": { "…": "the full current attempt record" }
}
```

- `task_state`: `created` · `running` · `awaiting_supervisor` · `accepted` · `rejected` · `cancelled` · `taken_over`.
- `state` is the older per-attempt vocabulary (`running`/`completed`/`incomplete`/`failed`/`timeout`/`cancelled`), kept for compatibility.
- `liveness` is non-null only while an attempt runs: `process_alive`, `elapsed_seconds`, `last_provider_activity_seconds`, `idle_seconds`, `possibly_stalled`. It comes from provider telemetry, not from heartbeat messages. `possibly_stalled` is a hint — never cancel on it alone. The hard timeout remains the only automatic stop.
- `changed_files` is the worktree diff between launch and finish — a review aid, not an audit log: a file already dirty in the same way is invisible to it. It stays the objective record and is never filtered.
- `worker_attributed_files` is that diff narrowed to what the worker itself reported touching, and `unattributed_files` is the remainder — a file the worker forgot to list, or another attempt's edit in the same tree. The worker is untrusted, so read these as a split of the diff, never as a replacement for it.

`show TASK --json` adds the full `attempts[]`, `verifications[]` and `events[]` arrays.

## Concurrency

**Concurrent delegations are allowed.** Nothing serializes them: several Tasks may run at once, in one worktree or across several. Two well-scoped tasks in one tree do not fight over files, but the launch-to-finish tree diff cannot tell their edits apart, so the wrapper says so on stderr at launch and you review `worker_attributed_files` instead of `changed_files`.

## Constraints

- Requires `opencode` **2.x** and `jq` on PATH — check with `scripts/install.sh --doctor`, which flags an unsupported OpenCode. A launch that fails before returning a Task id is an infrastructure failure (CLI missing or too old, auth, crash); inspect the output rather than blind-retrying.
- The worker runs as `opencode run --standalone`, a private OpenCode server owned by the attempt, so a timeout or `cancel` really stops the turn (through OpenCode's shared background service a turn outlives its killed client). The report, completion and cost come from `opencode session export`; the JSON event stream is the fallback. The worker starts in `--cwd` (or the current directory); a retry or resume continues in the directory its session was created in.
- A hard timeout (default 30 min) guarantees no attempt runs forever.
- Exit 0 only means the worker ran and reported. Task success is decided by your verification run and your acceptance.
- Job directories from before the Task layout are still readable (`status <OLD_JOB_ID>` prints them, labelled `LEGACY JOB`) but are never reinterpreted as Tasks and never appear in `list`.
