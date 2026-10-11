---
name: opencode-subagent
description: 'Delegate bounded, mechanically verifiable implementation to a cheap OpenCode worker, or research and review to a read-only OpenCode researcher with web access, then verify the result yourself. Use when the user asks to delegate to OpenCode or runs /opencode-subagent; under delegation_policy=auto, before a long read/edit/test loop on settled work; before creating or messaging a native subagent (Agent, SendMessage, spawn_agent, followup_task); and when an opencode-subagent routing hook denies one.'
argument-hint: 'Required: the task to delegate. Optional: model as provider/model (defaults to the configured worker model).'
---

# OpenCode Subagent

You are the **supervisor**. `opencode run` is a **worker**: `workflow-worker` edits code, `workflow-researcher` reads, searches the web and reports. This skill launches it on a bounded task, tracks every attempt, and keeps a durable record of what was asked, what happened, what you verified and what you decided.

The savings come from context isolation (the worker's loop never enters your context) and price arbitrage (a cheap model). An under-specified task loses both.

`opencode-delegate` is on PATH after `scripts/install.sh`; otherwise call `bash <this skill dir>/scripts/delegate.sh` with the same arguments. Requires OpenCode **2.x** and `jq` (`scripts/install.sh --doctor`); an older CLI exits `127` before a Task exists.

## References

Load one only when its branch comes up:

| File | When |
|---|---|
| [references/routing.md](references/routing.md) | A routing hook denied a native call, or you are recording a routing decision (flags, routes, read-only agents, rules) |
| [references/operations.md](references/operations.md) | You need a command, option or exit code not shown below, or the `--json` field meanings |
| [references/recovery.md](references/recovery.md) | Picking up Tasks from another session, a crash, `recover`, or state paths and retention |
| [references/agents-and-config.md](references/agents-and-config.md) | Worker or researcher permissions, `subagents.conf` keys, model resolution |

## Responsibility

You own intent, architecture, decomposition, ambiguous and security-sensitive calls, and **accepting or rejecting the result**. The worker owns executing the bounded task, running the verification you specified, and a structured report. The worker is untrusted: its report is evidence, never acceptance.

A **Task** is your unit of intent and survives retries. An **Attempt** is one worker execution. Attempts usually share one OpenCode **session** (`ses_…`), so a correction keeps the worker's context. A **Verification** is a command *you* ran, with exit code and output stored.

Every Task has four outcome dimensions; never collapse them into one "did it work":

| Dimension | Values |
|---|---|
| `transport` | `not_started` · `running` · `finished` · `incomplete` · `failed` · `timeout` · `cancelled` |
| `worker` | `pending` · `done` · `done_with_concerns` · `blocked` · `no_report` · `failed` |
| `verification` | `not_run` · `passed` · `failed` · `error` |
| `supervisor` | `pending` · `decision_required` · `retry` · `accepted` · `rejected` · `cancelled` · `taken_over` |

`transport: finished, worker: done` is the worker's claim. Success is `verification: passed` plus your own review.

## When to delegate

> If deciding **what** to do is the hard part, keep the task. If **doing** it is mechanical and the outcome is already understood, delegate it.

Required: known scope and decided architecture. Strongly preferred: success checkable by a command (test, lint, build). Good candidates: specified behavior, tests for defined behavior, repetitive refactors and migrations, propagating a known API or type change, localized type/lint fixes, boilerplate, applying a chosen pattern across files. Keep: design, choosing abstractions, unclear diagnosis, API/schema/auth/security decisions, vague requirements, refactors where the decomposition is the hard part. A one-line edit costs more to hand off than to make.

## Delegation policy

`opencode-delegate policy` reports it; `opencode-delegate policy <value>` changes it. It governs **all** delegation, native subagents included.

| Policy | Meaning |
|---|---|
| `off` | Never delegate. The wrapper refuses to launch. |
| `explicit` | Delegate only when the user or a calling workflow asks; their request is sufficient authorization. **Default.** |
| `auto` | You may delegate eligible mechanical work unasked; say in one line what and why. |

With the routing hooks installed, a native call that creates an agent or gives one more work is denied until you record a routing decision. The denial prints the command to run. Follow [references/routing.md](references/routing.md) for it; never retry in a loop or route around the hook.

## Research and review

`--role researcher` launches `workflow-researcher`: OpenCode read/grep/glob/list, read-only `git` and `gh`, `websearch`, `webfetch`. It cannot edit, run other shell commands, or delegate. Use it for exploration, web research, and independent review of a diff against a spec or the repo's standards.

```bash
opencode-delegate start --role researcher --cwd /abs/repo 'Review git diff origin/main...HEAD against AGENTS.md. Report findings ranked by severity with path:line and the failure scenario.'
opencode-delegate wait TASK
```

Findings come first in its report, then the `STATUS` block. Its model is `OPENCODE_SUBAGENT_RESEARCH_MODEL`, else the worker model. A Task keeps its role for life.

A review is never done by its author. If no review can be delegated (policy `off`, routing broken, no model, OpenCode failing), tell the user that no independent review ran.

## Lifecycle

```text
delegate → wait → interpret the worker outcome → verify independently
   → accept  OR  correct and retry  OR  take over
```

1. **Check the policy** for delegation the user did not request. Under `explicit` or `off`, do the work yourself.

2. **Write the job packet.** Task-specific facts only; the worker's standing rules live in its agent definition.

   ```text
   TASK
   Implement X.

   SCOPE
   - src/foo.ts
   - src/bar/

   CONSTRAINTS
   - preserve the public API

   ACCEPTANCE
   pnpm test foo
   pnpm typecheck
   ```

   With no concrete acceptance command, say so in one line and continue.

3. **Launch** blocking (`run`) when you need the result now, async (`start`) when you have other work:

   ```bash
   opencode-delegate run   [opts] "<job packet>"
   opencode-delegate start [opts] "<job packet>"    # prints a TASK id
   opencode-delegate wait  TASK --poll-timeout 300
   opencode-delegate wait  --any TASK1 TASK2       # several Tasks, one table
   ```

   A model the user named goes in exactly as `--model provider/model`, plus `--save-default` the first time (tell them it is saved).

   `wait` returns when the attempt ends, the provider is silent past `--stall-seconds` (default 300), or the stream reports a provider error, so a long `--poll-timeout` is safe; set your shell timeout above it. Exit `3`: still running, poll again or `status TASK`. Exit `5`: running but silent; decide to keep waiting, inspect, or cancel rather than re-waiting at once. Silence is not proof of a hang. `wait --any` exits `0` once any Task is terminal, `3` while all run; per-Task state is in the table. Never abandon a running Task silently.

4. **Interpret** `outcome.worker`, not prose:

   | `worker` | Do |
   |---|---|
   | `done` / `done_with_concerns` | verify |
   | `blocked` | read `worker_question`, decide, resume (below) |
   | `no_report` | resume the same session |
   | `failed` | read `failure_class` |

   `recommended_action` is advice; nothing recovers automatically.

5. **Verify independently.** Read the diff of `changed_files` (with concurrent Tasks in one tree, `worker_attributed_files`), then run the acceptance command yourself:

   ```bash
   opencode-delegate verify TASK -- pnpm test foo
   ```

   Exit 0 passed, 1 ran and failed, 2 could not execute. Verification is refused while any attempt runs in the same worktree.

6. **Accept, correct, or take over.**

   ```bash
   opencode-delegate decide TASK accept --reason "diff matches the spec; pnpm test foo passes"
   opencode-delegate retry  TASK --reason "typecheck still fails in src/foo.ts" "fix: <narrow correction>"
   opencode-delegate decide TASK take_over --reason "two failed resumes; finishing in-context"
   ```

   `retry` reuses the session by default (`--new-session` to abandon it). After two failed corrections, take over in-context.

### When the worker is BLOCKED

The worker stops rather than invent architectural or product decisions; the Task moves to `supervisor: decision_required`. Answer it and resume the same session:

```bash
opencode-delegate show   TASK --json | jq -r '.attempts[-1].worker_question'
opencode-delegate decide TASK retry --reason "write-through; the cache must survive a crash"
opencode-delegate resume SESSION "Use write-through caching."
```

## Output rules

- Say what you delegated, to which model, and after verifying, the acceptance command and its actual result.
- Keep task ids, attempt ids and state paths out of the conversation unless the user asks or a Task stalls or fails.
- Claim success only alongside your own verification output.
