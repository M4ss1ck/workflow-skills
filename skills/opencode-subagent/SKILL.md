---
name: opencode-subagent
description: 'Delegate bounded, mechanically verifiable implementation work to a cheap OpenCode worker, and research or review to a cheap read-only OpenCode researcher with web access, then verify the result yourself. Use when the user asks to delegate to OpenCode ("delegate this to opencode", "have opencode implement this", "/opencode-subagent"), and — when delegation_policy=auto — when you are about to spend a long read/edit/test loop on work whose design is already settled. Also use before creating or messaging a native subagent (Agent, SendMessage, spawn_agent, followup_task), and whenever an opencode-subagent routing hook denies one. This runs a paid external CLI: respect the configured delegation policy.'
argument-hint: 'Required: the task to delegate. Optional: model as provider/model (defaults to the configured worker model).'
---

# OpenCode Subagent

You are the **supervisor**. `opencode run` is a **worker**. This skill is the transport and the durable record between you: it launches a constrained OpenCode agent on a bounded task (`workflow-worker` edits code; `workflow-researcher` reads, searches the web and reports), tracks every attempt, and keeps a reconstructable history of what was asked, what happened, what you verified, and what you decided.

The savings come from context isolation (the worker's read/edit/test loop never enters your context) and price arbitrage (the worker runs a cheap model). Both are lost if the task is under-specified.

## Invoking it

`opencode-delegate` is on PATH once `scripts/install.sh` has run. If it is not (a host where the skill was copied rather than installed), call the script directly: `bash <this skill dir>/scripts/delegate.sh` — every command below is otherwise identical. `opencode-delegate help` prints the full command reference.

Requires **OpenCode 2.x**. OpenCode 1.x is not supported: every launch checks `opencode --version` and refuses an older CLI with exit `127` before a Task is created.

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

## Research and review: the researcher role

`--role researcher` launches `workflow-researcher` instead of the worker: it reads the tree with OpenCode's read/grep/glob/list tools, runs a short list of read-only `git` and `gh` commands, and uses `websearch` and `webfetch`. It cannot edit files, run any other shell command, read `.env` files through its tools, or delegate. Use it for codebase exploration, web research, and independent reviews of a diff against a spec or the repo's standards.

```bash
opencode-delegate start --role researcher --cwd /abs/repo 'Review the diff from git diff origin/main...HEAD against AGENTS.md. Report findings ranked by severity with path:line and the failure scenario.'
opencode-delegate wait TASK
```

Its findings come first in its report, followed by the usual `STATUS` block; `status` and `wait` print a researcher's report in full. Its model is `OPENCODE_SUBAGENT_RESEARCH_MODEL`, falling back to the worker model. A Task keeps its role for life: `retry` and `resume` reuse it and refuse a different `--role`.

A review is never done by its author. If a review cannot be delegated (policy `off`, routing broken, no researcher model configured, OpenCode missing or failing to launch), tell the user that no independent review ran. Do not review your own work in its place.

## Delegation policy

`delegate.sh policy` reports the effective setting; `delegate.sh policy <value>` changes it.

| Policy | Meaning |
|---|---|
| `off` | Never delegate. The wrapper refuses to launch. |
| `explicit` | Delegate only when the user or calling workflow asks for it. **Default.** |
| `auto` | You may proactively delegate eligible mechanical work without being asked. |

Under `explicit`, the user's request is sufficient authorization. Under `auto`, apply the table above yourself and say in one line what you delegated and why.

The policy governs **all** delegation, native subagents included, not only OpenCode launches.

## Native delegation routing

With the routing hooks installed (Claude Code and Codex CLI only; see `opencode-delegate route doctor`), every native call that creates an agent or gives an existing one more work is denied until a routing decision is recorded for it. Status, wait and cancel calls are never blocked.

When a hook denies a native call, the denial carries a ready-made command and the route it will produce for each work kind under the current policy. Record the decision and follow the printed route:

```bash
opencode-delegate route record --proposal PROPOSAL --skill-revision REVISION \
  --assignment parser-review --work-kind implementation|research|review \
  --scope "review the parser diff against the spec"
```

Every other field defaults to its cautious value. Add only what is true:

| Flag | When |
|---|---|
| `--authorization user --source-excerpt "..."` | The user asked for delegation. Quote their words verbatim from a message in this session. |
| `--authorization workflow --source-excerpt "..."` | A skill the user invoked in this session (for example `/implement`), or a committed `AGENTS.md`/`CLAUDE.md`/`GEMINI.md`/`SKILL.md` named with `--workflow-file`, asks for it. Skills you loaded yourself, and this skill, do not count. |
| `--requested-provider opencode\|native` | That source names a provider. |
| `--native-reason needs-host-tools` | Research or review that needs tools only the host has (MCP servers, the browser). |
| `--native-reason opencode-failed --opencode-task TASK` | Research or review already routed to OpenCode under this `--assignment`, whose researcher Task ran and failed: the worker reported blocked, failed or no report, the Task has a failure class (timeout, crash, provider error), or you rejected it. A cancel or take-over on its own does not count. |
| `--scope-status ambiguous\|conflicting` | You cannot state the scope cleanly. |

| Route | Do |
|---|---|
| `native` | Repeat the native call **once**, before the next user message, from the same worktree. The hook runs the proposal exactly as first submitted, even if you reword it. |
| `opencode` | Do not repeat the native call. Delegate with the printed `opencode-delegate start --role worker\|researcher` command and verify. |
| `local` | Do not repeat the native call. Do the work yourself. Never returned for a review. |
| `none` | Delegation is off. Do the work yourself, except a review: say no independent review ran. |
| `clarify` | Ask the user to resolve the scope, or work locally (not a review). |

The router computes the route; you only supply facts. How it decides:

| Policy and record | Route |
|---|---|
| `off` | `none` |
| scope not `clear` | `clarify` |
| assignment previously routed to OpenCode | `opencode`, unless a **later** user message explicitly asks for native, or research/review with `opencode-failed` and a failed Task |
| `--requested-provider opencode` (user or workflow source) | `opencode` |
| `--requested-provider native` with a user source, or a workflow source for research/review | `native` |
| `explicit`, `--authorization none`, implementation or research | `local`: you choosing to delegate is not authorization |
| implementation | `opencode` worker |
| research or review with `--native-reason needs-host-tools` | `native` (an unauthorized review under `explicit`: `clarify`, ask the user; unauthorized research was already `local`) |
| research or review | `opencode` researcher (a review even when nobody authorized delegation: it needs a reviewer who is not the author) |

Read-only agent types skip routing entirely: no proposal, no grant, one `allow_readonly` audit entry. `Explore`, `Plan` and `claude-code-guide` always do. `OPENCODE_SUBAGENT_READONLY_AGENTS` adds patterns to them (separated by spaces or commas; default `*-reviewer *-explorer`; an empty value leaves only those three). A follow-up `SendMessage` to such an agent passes too, once its create call has returned, when addressed by the agent id the host returned. A follow-up by name is gated: the host assigns and reuses names, so a name can come to mean a writing agent. Follow-ups need the `PostToolUse` routing hook: if `opencode-delegate route doctor` says a registration lacks it, re-run `scripts/install.sh` (local install) or update the plugin. An existing `OPENCODE_SUBAGENT_READONLY_AGENTS=` with no value used to turn the bypass off; it now keeps the three built-ins. It is a name allowlist, not a sandbox, built-ins included: an agent definition in a checkout can call itself `x-reviewer` and still have write tools. Not under policy `off`, and Claude Code only.

Rules:

- `--source-excerpt` must be quoted verbatim from a user message in this session, a skill the user invoked, or a `--workflow-file`. Quoting a mention, a negation ("don't use opencode") or a file the user pasted is misrecording; the router checks the words exist, not what they mean.
- Keep the same `--assignment` slug for the same piece of work. An explicit OpenCode assignment stays OpenCode: if OpenCode fails on implementation, report it and work locally; going native needs a new explicit user instruction.
- Do not relabel implementation as research to get a different route.
- A denial that says the router cannot evaluate the call (broken state, runtime mismatch, no captured user input) means work locally (a review: report that none ran) and tell the user what `opencode-delegate route doctor` reports. Never retry in a loop, and never route around the hook through a shell or another CLI.
- A grant belongs to the agent that recorded it: a subagent cannot spend its parent's grant. Parallel native calls each need their own recorded decision.
- A new user message, a policy change, compaction or resume retires unused grants. Grants expire after 30 minutes.

## Lifecycle

```text
delegate → inspect → wait → interpret the worker outcome → verify independently
   → accept  OR  record a correction and retry  OR  take over
```

1. **Check the policy** when considering delegation the user did not request: `opencode-delegate policy`. If `explicit` or `off`, do the work yourself. The same applies to native subagents (see Native delegation routing).

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
   opencode-delegate run   [opts] "<job packet>"    # blocks
   opencode-delegate start [opts] "<job packet>"    # returns a TASK id at once
   opencode-delegate wait  TASK --poll-timeout 300
   ```

   If the user named a model, pass it exactly via `--model provider/model` — never substitute or "upgrade" their choice — and add `--save-default` the first time so it becomes the configured worker model (tell them it is saved).

   `wait` blocks until there is something worth reporting: the attempt ends, the provider goes quiet for longer than `--stall-seconds` (default 300), or the stream carries a provider error. A long `--poll-timeout` is safe because of that.

   With several Tasks in flight, poll them together: `wait --any TASK1 TASK2` returns one table and exits `0` as soon as any is terminal, `3` while all are still running. Those codes are the aggregate only — each Task's state, worker outcome and exit code are columns in the table, and `--json` returns one object per Task.

   Set your shell tool's own timeout above `--poll-timeout`. Exit 3 means still running: poll again, or check without blocking via `status TASK`. **Exit 5 means still running but silent** — the worker has recorded nothing for the stall window. Decide: keep waiting, inspect the stream, or cancel. Do not immediately re-wait, which would spin until the hard timeout. Silence is not proof of a hang: a worker running one long command looks identical, so nothing is ever cancelled for it. Never abandon a running task silently.

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
   opencode-delegate verify TASK -- pnpm test foo
   ```

   Exit 0 = passed, 1 = the command ran and failed, 2 = the command could not be executed; every result stores the command, cwd, timings, exit code and output on the Task. Verification is refused while any attempt is running in the same worktree — this Task's or another's — because a result measured mid-edit means nothing. A worker claiming its tests pass is not verification.

6. **Accept, correct, or take over.**

   ```bash
   opencode-delegate decide TASK accept --reason "diff matches the spec; pnpm test foo passes"
   opencode-delegate retry  TASK --reason "typecheck still fails in src/foo.ts" "fix: <narrow correction>"
   opencode-delegate decide TASK take_over --reason "two failed resumes; finishing in-context"
   ```

   `retry` creates the next Attempt on the same Task, links it with `retry_of`, and reuses the same OpenCode session by default (`--new-session` to abandon it). **After two failed corrections, take the task over in-context** rather than retrying a third time.

### When the worker is BLOCKED

The worker must not invent architectural or product decisions. When it stops with `STATUS: BLOCKED`, the attempt ends cleanly and the Task moves to `supervisor: decision_required`.

```bash
opencode-delegate show   TASK --json | jq -r '.attempts[-1].worker_question'
opencode-delegate decide TASK retry --reason "write-through; the cache must survive a crash"
opencode-delegate resume SESSION "Use write-through caching."
```

Answer it and resume the same session. Do not re-delegate the same ambiguity.

**Concurrent delegations are allowed.** Nothing serializes them: several Tasks may run at once, in one worktree or across several. Two well-scoped tasks in one tree do not fight over files, but the launch-to-finish tree diff cannot tell their edits apart, so the wrapper says so on stderr at launch and you review `worker_attributed_files` instead of `changed_files`.

## Operations

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

## The agents

`agents/workflow-worker.md` and `agents/workflow-researcher.md` are installed into OpenCode's agent directory (by `scripts/install.sh --agent opencode`, and by `delegate.sh` before each launch). The worker enforces, in OpenCode's own permission system rather than by asking nicely:

- no recursive delegation (`task: deny`) and no questions to a user who is not there (`question: deny`);
- no web search or fetch (use the researcher for that);
- no writes outside the working tree;
- no `git commit`, `push`, `reset --hard`, `clean`, `rebase`, `checkout`, `switch`, `stash`, or branch deletion;
- normal read/search/edit/LSP/test/build access;
- temperature 0 and a bounded step count.

It ends its turn with `STATUS` / `FILES_CHANGED` / `VERIFICATION` / `QUESTION` / `CONCERNS`, which the wrapper parses into `outcome.worker` and `worker_question`.

The researcher has the same reporting contract, with its findings written above the block. Its shell runs only `git status/diff/log/show/blame/ls-files/rev-parse/merge-base`, `gh pr view/diff` and `gh issue view`, one plain command at a time. Pipes into anything else, redirection, `$`/backtick substitution, `--output`, `--ext-diff`, `--textconv`, `--no-index`, `difftool` and any argument naming `.env` are denied; files are read with OpenCode's own tools, whose `read` denies `.env` files. General tools such as `cat`, `find`, `rg` or `sort` are left out on purpose: several have flags that write files or run programs, and this agent also has the network. The `.env` blocking covers its tools, not every way a secret can sit in a tree, so do not point it at repositories whose secrets live in tracked files.

## Configuration

`~/.config/workflow-skills/subagents.conf` (shared with the other `*-subagent` skills):

```ini
OPENCODE_SUBAGENT_DELEGATION_POLICY=auto
OPENCODE_SUBAGENT_MODEL=provider/some-cheap-coding-model
OPENCODE_SUBAGENT_RESEARCH_MODEL=provider/some-cheap-model
OPENCODE_SUBAGENT_READONLY_AGENTS=*-reviewer *-explorer
OPENCODE_SUBAGENT_STALL_SECONDS=300
OPENCODE_SUBAGENT_RETENTION_DAYS=90
OPENCODE_SUBAGENT_RAW_RETENTION_DAYS=7
```

`OPENCODE_SUBAGENT_MODEL` is the worker model. Resolution is: `--model` → configured worker model → **error**. The wrapper never falls back to whatever model OpenCode uses globally; inheriting a frontier model would defeat the purpose. Set it once with `--model provider/model --save-default`. `OPENCODE_SUBAGENT_RESEARCH_MODEL` is the researcher's model (`--role researcher --model ... --save-default` sets it); unset, the researcher uses the worker model. With no policy key the policy is `explicit`.

## Constraints

- Requires `opencode` **2.x** and `jq` on PATH — check with `scripts/install.sh --doctor`, which flags an unsupported OpenCode. A launch that fails before returning a Task id is an infrastructure failure (CLI missing or too old, auth, crash); inspect the output rather than blind-retrying.
- The worker runs as `opencode run --standalone`, a private OpenCode server owned by the attempt, so a timeout or `cancel` really stops the turn (through OpenCode's shared background service a turn outlives its killed client). The report, completion and cost come from `opencode session export`; the JSON event stream is the fallback. The worker starts in `--cwd` (or the current directory); a retry or resume continues in the directory its session was created in.
- A hard timeout (default 30 min) guarantees no attempt runs forever.
- Exit 0 only means the worker ran and reported. Task success is decided by your verification run and your acceptance.
- Job directories from before the Task layout are still readable (`status <OLD_JOB_ID>` prints them, labelled `LEGACY JOB`) but are never reinterpreted as Tasks and never appear in `list`.

## Output rules

- Say what you delegated, to which model, and — after verifying — the acceptance command and its actual result.
- Do **not** dump task ids, attempt ids, `tail -f` commands, or state paths into the conversation by default. "Delegated the mechanical implementation to the configured OpenCode worker" is the normal report. Surface internal details when the user asks, when a task stalls or fails, or when the orchestration environment needs them to recover.
- Never claim the delegated task succeeded without showing your own verification output.
