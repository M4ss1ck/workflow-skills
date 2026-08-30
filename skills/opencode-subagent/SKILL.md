---
name: opencode-subagent
description: 'Delegate bounded, mechanically verifiable implementation work to a cheap OpenCode worker and verify the result yourself. Use when the user asks to delegate to OpenCode ("delegate this to opencode", "have opencode implement this", "/opencode-subagent"), and — when delegation_policy=auto — when you are about to spend a long read/edit/test loop on work whose design is already settled. This runs a paid external CLI: respect the configured delegation policy.'
argument-hint: 'Required: the task to delegate. Optional: model as provider/model (defaults to the configured worker model).'
---

# OpenCode Subagent

You are the **supervisor**. `opencode run` is a **worker**. This skill is the transport and the durable record between you: it launches a constrained OpenCode agent (`workflow-worker`) on a bounded task, tracks every attempt, and keeps a reconstructable history of what was asked, what happened, what you verified, and what you decided.

The savings come from context isolation (the worker's read/edit/test loop never enters your context) and price arbitrage (the worker runs a cheap model). Both are lost if the task is under-specified.

## Division of responsibility

| Supervisor (you) owns | Worker owns |
|---|---|
| Understanding user intent | Executing the bounded task as given |
| Architecture and abstractions | File edits |
| Decomposition into delegable units | Mechanical implementation |
| Ambiguous or contested decisions | Running the verification you specified |
| Security-sensitive judgment | A concise structured report |
| **Accepting or rejecting the result** | |

The worker is an untrusted executor. Its report is evidence, never acceptance.

## The four nouns

| Term | What it is |
|---|---|
| **Task** | Your unit of intent. Survives retries. Has an id like `task_20260813-101500-4821`. |
| **Attempt** | One worker execution: `attempt_001`, `attempt_002`, … Each persists the exact request it sent. |
| **OpenCode session** | The provider's conversation (`ses_…`). Several attempts usually share one, so a correction keeps the worker's context. |
| **Verification** | A command *you* ran outside the worker's turn, with its exit code and output stored. |

## The four outcome dimensions

Never collapse these into one "did it work".

| Dimension | Values |
|---|---|
| `transport` | `not_started` · `running` · `finished` · `incomplete` · `failed` · `timeout` · `cancelled` |
| `worker` | `pending` · `done` · `done_with_concerns` · `blocked` · `no_report` · `failed` |
| `verification` | `not_run` · `passed` · `failed` · `error` |
| `supervisor` | `pending` · `decision_required` · `retry` · `accepted` · `rejected` · `cancelled` · `taken_over` |

`transport: finished, worker: done` means the worker finished and claims success. It is **not** success. Only `verification: passed` plus your own review makes it so.

## When to delegate

> If deciding **what** to do is the hard part, keep the task. If **doing** it is repetitive or mechanical and the outcome is already understood, delegate it.

| Property of the task | Guidance |
|---|---|
| Scope is known | required before delegating |
| Architecture already decided | required before delegating |
| Success is mechanically verifiable (test/lint/build) | strongly preferred |
| Localized or repetitive execution | good candidate |
| Meaningful read/edit/test or context burden | good candidate |
| Needs interpretation of the user's intent | keep it |
| Security-sensitive judgment | keep it |
| Broad exploratory reasoning or unclear diagnosis | usually keep it |

Good candidates: implementing already-specified behavior; writing tests for defined behavior; repetitive refactors and migrations; propagating a known API or type change; fixing localized type/lint failures after a decided change; boilerplate; applying an already-chosen pattern across files; running an implementation loop whose success can be checked by a command.

Poor candidates: architectural design; choosing abstractions; diagnosing an unclear bug; API or schema design; auth and security decisions; interpreting vague requirements; cross-cutting refactors where the decomposition *is* the hard problem.

**Do not delegate merely because a task is easy.** A one-line edit costs more to hand off than to make.

## Delegation policy

`delegate.sh policy` reports the effective setting; `delegate.sh policy <value>` changes it.

| Policy | Meaning |
|---|---|
| `off` | Never delegate. The wrapper refuses to launch. |
| `explicit` | Delegate only when the user or calling workflow asks for it. **Default.** |
| `auto` | You may proactively delegate eligible mechanical work without being asked. |

Under `explicit`, the user's request is sufficient authorization. Under `auto`, apply the table above yourself and say in one line what you delegated and why.

## Lifecycle

```text
delegate → inspect → wait → interpret the worker outcome → verify independently
   → accept  OR  record a correction and retry  OR  take over
```

1. **Check the policy** when considering delegation the user did not request: `bash scripts/delegate.sh policy`. If `explicit` or `off`, do the work yourself.

2. **Write the job packet.** Task-specific facts only — the worker's standing rules (no redesign, no further delegation, no commits, report format) live in its agent definition.

   ```text
   TASK
   Implement X.

   SCOPE
   Relevant starting points:
   - src/foo.ts
   - src/bar/

   CONSTRAINTS
   - preserve the public API
   - do not modify the database schema

   ACCEPTANCE
   pnpm test foo
   pnpm typecheck
   ```

   If the task has no concrete acceptance command, say so in one line and continue.

3. **Launch.** Blocking when you cannot proceed without the result, async when you have other work:

   ```bash
   bash scripts/delegate.sh run   [opts] "<job packet>"    # blocks
   bash scripts/delegate.sh start [opts] "<job packet>"    # returns a TASK id at once
   bash scripts/delegate.sh wait  TASK --poll-timeout 300
   ```

   If the user named a model, pass it exactly via `--model provider/model` — never substitute or "upgrade" their choice — and add `--save-default` the first time so it becomes the configured worker model (tell them it is saved).

   Set your shell tool's own timeout above `--poll-timeout`. Exit 3 means still running: poll again, or check without blocking via `status TASK`. Never abandon a running task silently.

4. **Interpret the worker outcome** from `outcome.worker`, not from prose:

   | `worker` | Meaning | Do |
   |---|---|---|
   | `done` / `done_with_concerns` | finished and claims success | verify |
   | `blocked` | hit a decision that is yours | read `worker_question`, `decide`, then resume |
   | `no_report` | the turn ended without a valid final report | resume the same session |
   | `failed` | died before reaching a semantic result | read `failure_class` |

   `recommended_action` names the usual next step (`verify`, `resume_same_session`, `retry_new_session`, `supervisor_decision`, `inspect_diff`, `repair_infrastructure`, `take_over`, `wait`, `cancel`). It is advice. You decide, and nothing recovers automatically.

5. **Verify independently.** Read the diff of `changed_files`, then run the acceptance command *yourself* through the recorder:

   ```bash
   bash scripts/delegate.sh verify TASK -- pnpm test foo
   ```

   Exit 0 = passed, 1 = the command ran and failed, 2 = the command could not be executed; every result stores the command, cwd, timings, exit code and output on the Task. Verification is refused while any attempt is running in the same worktree — this Task's or another's — because a result measured mid-edit means nothing. A worker claiming its tests pass is not verification.

6. **Accept, correct, or take over.**

   ```bash
   bash scripts/delegate.sh decide TASK accept --reason "diff matches the spec; pnpm test foo passes"
   bash scripts/delegate.sh retry  TASK --reason "typecheck still fails in src/foo.ts" "fix: <narrow correction>"
   bash scripts/delegate.sh decide TASK take_over --reason "two failed resumes; finishing in-context"
   ```

   `retry` creates the next Attempt on the same Task, links it with `retry_of`, and reuses the same OpenCode session by default (`--new-session` to abandon it). **After two failed corrections, take the task over in-context** rather than retrying a third time.

### When the worker is BLOCKED

The worker must not invent architectural or product decisions. When it stops with `STATUS: BLOCKED`, the attempt ends cleanly and the Task moves to `supervisor: decision_required`.

```bash
bash scripts/delegate.sh show   TASK --json | jq -r '.attempts[-1].worker_question'
bash scripts/delegate.sh decide TASK retry --reason "write-through; the cache must survive a crash"
bash scripts/delegate.sh resume SESSION "Use write-through caching."
```

Answer it and resume the same session. Do not re-delegate the same ambiguity.

**Concurrent delegations are allowed.** Nothing serializes them: several Tasks may run at once, in one worktree or across several. Two well-scoped tasks in one tree do not fight over files, but the launch-to-finish tree diff cannot tell their edits apart, so the wrapper says so on stderr at launch and you review `worker_attributed_files` instead of `changed_files`.

## Operations

```bash
bash scripts/delegate.sh start  [opts] "<task>"        # launch Attempt 1 detached
bash scripts/delegate.sh run    [opts] "<task>"        # launch and block
bash scripts/delegate.sh retry  TASK --reason R "<fix>"# next Attempt, same session by default
bash scripts/delegate.sh resume SESSION "<fix>"        # next Attempt on the Task owning SESSION
bash scripts/delegate.sh status TASK                   # state + liveness, no blocking
bash scripts/delegate.sh wait   TASK [--poll-timeout SECS]
bash scripts/delegate.sh verify TASK [--label L] -- CMD ARGS...
bash scripts/delegate.sh decide TASK DECISION --reason R
bash scripts/delegate.sh cancel TASK [--keep-task]     # stop the running Attempt
bash scripts/delegate.sh list   [--active] [--limit N]
bash scripts/delegate.sh show   TASK                   # task + attempts + verifications + history
bash scripts/delegate.sh attempts TASK
bash scripts/delegate.sh events TASK
bash scripts/delegate.sh logs   TASK [ATTEMPT] [--stream report|request|raw|stderr|progress|result|meta|changed]
bash scripts/delegate.sh recover                       # reconcile state after a crash
bash scripts/delegate.sh policy [off|explicit|auto]
```

Decisions: `accept` · `retry` · `reject` · `cancel` · `take_over` · `continue_waiting`. `--reason` is required for `retry`, `reject` and `take_over` — the reason is the durable record of why.

Options: `--model provider/model`, `--cwd DIR`, `--resume SESSION_ID`, `--new-session`, `--reason TEXT`, `--label TEXT`, `--timeout SECS` (default 1800), `--poll-timeout SECS`, `--save-default`, `--json`.

Exit codes: `0` finished · `1` verification failed · `2` usage/config or verification-execution error · `3` still running · `4` incomplete turn, resume the session · `124` timeout · `127` missing CLI · `130` cancelled.

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

## Recovering supervision

Nothing important lives only in your conversation. A fresh supervisor with no context can pick up any Task:

```bash
bash scripts/delegate.sh recover --json          # reconcile crashed/interrupted attempts first
bash scripts/delegate.sh list --active --json    # what is still open
bash scripts/delegate.sh show TASK               # the whole story, in order
bash scripts/delegate.sh logs TASK attempt_002 --stream request   # exactly what was asked
```

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
  meta.json result.json worker-report.txt changed-files.txt
  pid process.json provider.pid provider-process.json
  raw.jsonl stderr.log provider-progress.json
```

On Linux, each persisted process identity includes the kernel boot ID and `/proc` start time as well as the PID, so a reboot or reused numeric PID is not mistaken for the old process. Other platforms fall back to `kill -0` liveness.

`task.json` is authoritative for current state. `events.jsonl` is the append-only audit history, not a state-replay log. While holding the per-Task lock, a command atomically replaces `task.json` first and then appends the corresponding event. A crash in that narrow gap can leave current state newer than the history; `recover` reconciles attempt completion idempotently without duplicating terminal events. Event sequence numbers are unique and gap-free for the events that were durably appended.

Jobs are detached and survive your session. Retention is configurable in `subagents.conf`: terminal Task history is kept for `OPENCODE_SUBAGENT_RETENTION_DAYS` (default 90), while its bulky provider streams (`raw.jsonl`, `provider-progress.json`, git snapshots) are dropped after `OPENCODE_SUBAGENT_RAW_RETENTION_DAYS` (default 7). Active and unresolved Tasks are never pruned. Pruning runs on launch and does not inspect or remove sibling Claude/Codex state.

## The worker agent

`agents/workflow-worker.md` is installed into OpenCode's agent directory (by `scripts/install.sh --agent opencode`, and by `delegate.sh` on first launch). It enforces, in OpenCode's own permission system rather than by asking nicely:

- no recursive delegation (`task: deny`) and no questions to a user who is not there (`question: deny`);
- no web search or fetch;
- no writes outside the working tree;
- no `git commit`, `push`, `reset --hard`, `clean`, `rebase`, `checkout`, `switch`, `stash`, or branch deletion;
- normal read/search/edit/LSP/test/build access;
- temperature 0 and a bounded step count.

It ends its turn with `STATUS` / `FILES_CHANGED` / `VERIFICATION` / `QUESTION` / `CONCERNS`, which the wrapper parses into `outcome.worker` and `worker_question`.

## Configuration

`~/.config/workflow-skills/subagents.conf` (shared with the other `*-subagent` skills):

```ini
OPENCODE_SUBAGENT_DELEGATION_POLICY=auto
OPENCODE_SUBAGENT_MODEL=provider/some-cheap-coding-model
OPENCODE_SUBAGENT_RETENTION_DAYS=90
OPENCODE_SUBAGENT_RAW_RETENTION_DAYS=7
```

`OPENCODE_SUBAGENT_MODEL` is the worker model. Resolution is: `--model` → configured worker model → **error**. The wrapper never falls back to whatever model OpenCode uses globally; inheriting a frontier model would defeat the purpose. Set it once with `--model provider/model --save-default`. With no policy key the policy is `explicit`.

## Constraints

- Requires `opencode` and `jq` on PATH — check with `scripts/install.sh --doctor`. A launch that fails before returning a Task id is an infrastructure failure (CLI missing, auth, crash); inspect the output rather than blind-retrying.
- A hard timeout (default 30 min) guarantees no attempt runs forever.
- Exit 0 only means the worker ran and reported. Task success is decided by your verification run and your acceptance.
- Job directories from before the Task layout are still readable (`status <OLD_JOB_ID>` prints them, labelled `LEGACY JOB`) but are never reinterpreted as Tasks and never appear in `list`.

## Output rules

- Say what you delegated, to which model, and — after verifying — the acceptance command and its actual result.
- Do **not** dump task ids, attempt ids, `tail -f` commands, or state paths into the conversation by default. "Delegated the mechanical implementation to the configured OpenCode worker" is the normal report. Surface internal details when the user asks, when a task stalls or fails, or when the orchestration environment needs them to recover.
- Never claim the delegated task succeeded without showing your own verification output.
