---
name: opencode-subagent
description: 'Delegate bounded, mechanically verifiable implementation work to a cheap OpenCode worker and verify the result yourself. Use when the user asks to delegate to OpenCode ("delegate this to opencode", "have opencode implement this", "/opencode-subagent"), and — when delegation_policy=auto — when you are about to spend a long read/edit/test loop on work whose design is already settled. This runs a paid external CLI: respect the configured delegation policy.'
argument-hint: 'Required: the task to delegate. Optional: model as provider/model (defaults to the configured worker model).'
---

# OpenCode Subagent

You are the **supervisor**. `opencode run` is a **worker**. This skill is the transport between you: it launches a constrained OpenCode agent (`workflow-worker`) on a bounded task, tracks the job, and hands you back a report you must verify.

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

Good candidates: implementing already-specified behavior; writing tests for defined behavior; repetitive refactors and migrations; propagating a known API or type change; fixing localized type/lint failures after a decided change; boilerplate; applying an already-chosen pattern across files; mechanical documentation updates; running an implementation loop whose success can be checked by a command.

Poor candidates: architectural design; choosing abstractions; diagnosing an unclear bug; API or schema design; auth and security decisions; interpreting vague requirements; cross-cutting refactors where the decomposition *is* the hard problem.

**Do not delegate merely because a task is easy.** A one-line edit costs more to hand off than to make. Delegate when moving the execution loop out of your context materially saves tokens, context, or cost.

## Delegation policy

`delegate.sh policy` reports the effective setting; `delegate.sh policy <value>` changes it.

| Policy | Meaning |
|---|---|
| `off` | Never delegate. The wrapper refuses to launch. |
| `explicit` | Delegate only when the user or calling workflow asks for it. **Default.** |
| `auto` | You may proactively delegate eligible mechanical work without being asked. |

Under `explicit`, the user's request is sufficient authorization — they decide when the spend is worth it, so support arbitrary delegations without second-guessing them. Under `auto`, apply the table above yourself and say in one line what you delegated and why.

## Procedure

1. **Check the policy** when you are considering delegation the user did not request: `bash scripts/delegate.sh policy`. If it is `explicit` or `off`, do the work yourself.
2. **Write the job packet.** Task-specific facts only — the worker's standing rules (no redesign, no further delegation, no commits, report format) live in its agent definition, so do not restate them.

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

   If the task has no concrete acceptance command, say so in one line and continue — the delegation decision is the user's.
3. **Choose blocking or async** (see below) and launch. If the user named a model, pass it exactly via `--model provider/model` — never substitute or "upgrade" their choice — and add `--save-default` the first time so it becomes the configured worker model (tell them it is saved). Otherwise omit `--model` and the configured worker model applies.
4. **Verify independently.** Read the report and the diff of `changed_files`, then re-run the acceptance command yourself. Deciding whether the original task is satisfied is your call, not the worker's.
5. **Correct by resuming, not restarting.** On a failed verification or exit 4, resume the same session with a narrow correction. After two failed resumes, take the task over in-context.

```text
worker run → your verification → fail? → resume same session with a narrow fix
                                            → verify again → fail again → you take over
```

## Blocking vs asynchronous delegation

Both run detached; the difference is what you do while it works.

**Blocking** — you cannot proceed until the result is known:

```bash
bash scripts/delegate.sh run [--model provider/model] [--cwd DIR] [--timeout SECS] "<job packet>"
```

**Asynchronous** — you have independent work to do meanwhile:

```bash
bash scripts/delegate.sh start "<job packet>"      # returns a JOB id immediately
# ... do your own work ...
bash scripts/delegate.sh wait <JOB> --poll-timeout 300
```

Set your shell tool's own timeout above `--poll-timeout`. Exit 3 means still running — poll again, or check without blocking via `status <JOB>`. Never abandon a running job silently; if you must stop, `cancel <JOB>` or hand the user the job id.

**One delegation at a time per worktree.** The worker edits your working tree; concurrent workers would collide. Parallel fan-out needs separate git worktrees, which this wrapper does not yet manage.

## Operations

```bash
bash scripts/delegate.sh start  [opts] "<task>"     # launch detached
bash scripts/delegate.sh run    [opts] "<task>"     # launch and block
bash scripts/delegate.sh status JOB_ID              # state without blocking
bash scripts/delegate.sh wait   JOB_ID [--poll-timeout SECS]
bash scripts/delegate.sh resume SESSION_ID "<fix>"  # narrow correction, same context
bash scripts/delegate.sh cancel JOB_ID
bash scripts/delegate.sh policy [off|explicit|auto]
```

Options: `--model provider/model`, `--cwd DIR`, `--timeout SECS` (default 1800), `--save-default`, `--json`.

Add `--json` to any operation for a stable machine-readable object instead of prose:

```json
{
  "job_id": "opencode-20260808-101500",
  "state": "completed",
  "session_id": "ses_abc",
  "model": "openrouter/some-cheap-model",
  "agent": "workflow-worker",
  "cwd": "/repo",
  "exit_code": 0,
  "cost_usd": 0.031,
  "elapsed_seconds": 142,
  "state_dir": "/home/you/.local/state/workflow-skills/subagents/opencode-20260808-101500",
  "report": "STATUS: DONE\n...",
  "changed_files": ["src/foo.ts", "src/foo.test.ts"]
}
```

`state` is one of `running`, `completed`, `failed`, `timeout`, `incomplete`, `cancelled`. While running, `exit_code` and `report` are `null`. `changed_files` is the worktree diff between launch and finish — a review aid, not an audit log: a file that was already dirty in the same way is invisible to it.

Exit codes: `0` finished · `2` usage/config error · `3` still running · `4` incomplete turn, resume the session · `124` timeout · `127` missing CLI · `130` cancelled.

## The worker agent

`agents/workflow-worker.md` is installed into OpenCode's agent directory (by `scripts/install.sh --agent opencode`, and by `delegate.sh` on first launch). It enforces, in OpenCode's own permission system rather than by asking nicely:

- no recursive delegation (`task: deny`) and no questions to a user who is not there (`question: deny`);
- no web search or fetch;
- no writes outside the working tree;
- no `git commit`, `push`, `reset --hard`, `clean`, `rebase`, `checkout`, `switch`, `stash`, or branch deletion;
- normal read/search/edit/LSP/test/build access;
- temperature 0 and a bounded step count.

It returns `STATUS` / `FILES_CHANGED` / `VERIFICATION` / `CONCERNS`. `STATUS: BLOCKED` means the worker hit a decision that is yours to make — answer it and resume, do not re-delegate the same ambiguity.

## Configuration

`~/.config/workflow-skills/subagents.conf` (shared with the other `*-subagent` skills):

```ini
OPENCODE_SUBAGENT_DELEGATION_POLICY=auto
OPENCODE_SUBAGENT_MODEL=provider/some-cheap-coding-model
```

`OPENCODE_SUBAGENT_MODEL` is the worker model. Model resolution is: `--model` → configured worker model → **error**. The wrapper never falls back to whatever model OpenCode uses globally; inheriting a frontier model would defeat the purpose of delegating. Set it once with `--model provider/model --save-default`.

If the file has no policy key, the policy is `explicit`.

## Constraints

- Requires `opencode` and `jq` on PATH — check with `scripts/install.sh --doctor` from the workflow-skills repo. A launch that fails before returning a job id is an infrastructure failure (CLI missing, auth, crash); inspect the output rather than blind-retrying.
- Jobs are detached and survive your session. State lives under `~/.local/state/workflow-skills/subagents/<JOB>/` and is pruned after 7 days. A hard timeout (default 30 min) guarantees no job runs forever.
- Exit 0 only means the worker ran and reported. Task success is decided by your verification run.

## Output rules

- Say what you delegated, to which model, and — after verifying — the acceptance command and its actual result.
- Do **not** dump job ids, `tail -f` commands, status file paths, or progress commands into the conversation by default. "Delegated the mechanical implementation to the configured OpenCode worker" is the normal report. Surface internal job details only when the user asks, when the job stalls or fails, or when the orchestration environment needs them to recover.
- Never claim the delegated task succeeded without showing your own verification output.
