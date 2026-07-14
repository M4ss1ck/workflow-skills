---
name: opencode-subagent
description: 'Delegate a self-contained, mechanically verifiable task to an OpenCode subagent (any provider/model, typically a cheap one) and verify the result yourself. Use only when the user explicitly asks to delegate to OpenCode (e.g. "delegate this to opencode", "have opencode implement this", "/opencode-subagent"). This runs a paid external CLI — never invoke it proactively or on your own cost judgment.'
argument-hint: 'Required: the task to delegate. Optional: model as provider/model (defaults to the saved default in subagents.conf, then the user''s opencode config).'
---

# OpenCode Subagent

Delegate implementation work to `opencode run` in headless mode. The savings come from context isolation (the delegate's read/edit/test loop never enters your context) and price arbitrage (OpenCode can run any cheap model). Both are lost if the task is under-specified — the handoff contract below is mandatory.

## When to Use

- The user explicitly asked to delegate to OpenCode. Their request is sufficient authorization — they decide when the spend is worth it, so support arbitrary delegations without second-guessing them.
- Delegation pays off most when the task is self-contained and success is mechanically verifiable (tests, linter, build). If the request is exploratory or lacks a checkable outcome, say so in one line, then proceed as asked.

## Handoff Contract

The delegation spec MUST contain, in this order:
1. **Objective** — one sentence.
2. **Context** — the specific file paths and constraints that matter. No repo tour; the delegate can read files itself.
3. **Definition of done** — an exact command and its expected outcome.
4. **Boundaries** — files/areas not to touch, plus verbatim: "Do not delegate further; execute directly."
5. **Report format** — verbatim: "End with a report: files changed, verification output, open concerns."

## Procedure

1. If the task lacks a concrete definition of done, warn the user in one line and continue — the delegation decision is theirs.
2. Resolve the model: if the user named one, pass it exactly via `--model provider/model` — never substitute or "upgrade" their choice — and add `--save-default` the first time so it becomes their saved default (tell them it is now saved). If they named none, omit `--model`: the saved default from `~/.config/workflow-skills/subagents.conf` applies, or else the delegate's own configured default.
3. Write the spec per the Handoff Contract.
4. Launch (path relative to this skill's directory):
   `bash scripts/delegate.sh [--model provider/model] [--cwd DIR] [--timeout SECS] "<spec>"`
   This returns immediately with a `JOB:` id and `WATCH:` / `STATUS:` / `PROGRESS:` / `PROVIDER_REPORT:` / `RESULT:` lines.
5. Relay every returned monitoring command to the user right away, before waiting. `PROGRESS` is refreshed from OpenCode's local database once the session is observable, including on fresh runs and when a resumed CLI emits no stdout; `PROVIDER_REPORT` stores the best available final response.
6. Wait with bounded polls: `bash scripts/delegate.sh --wait <JOB> --poll-timeout 300`, setting your shell tool's own timeout above 300 s. Exit 3 means still running — poll again. Exit 4 means OpenCode produced assistant activity but no provider-final response — read the result and resume the returned session. Never abandon a running job silently; if you must stop, give the user the job id and the watch commands.
7. When the wait prints the result, read `SESSION:` (keep it for follow-ups), `COST:` (USD when reported), `EXIT:`, and the report after `--- REPORT ---`.
8. Re-run the definition-of-done command yourself when one exists. Never accept the report's success claim alone.
9. If the wait exits 4 or verification fails, resume — do not re-delegate from scratch:
   `bash scripts/delegate.sh --resume <SESSION> "fix: <specific correction>"`
   That launches a new job; follow it the same way. After two failed resumes, take the task over in-context.

## Constraints

- Requires `opencode` and `jq` on PATH — check with `scripts/install.sh --doctor` from the workflow-skills repo. A launch command that fails before returning a `JOB:` id is an infrastructure failure (CLI missing, auth, crash) — inspect the output; do not blind-retry.
- The subagent runs detached: job state lives under `~/.local/state/workflow-skills/subagents/<JOB>/` (`raw.jsonl`, `provider-progress.json`, `provider-report.txt`, `stderr.log`, `status`, `result.txt`) and survives your session. The wrapper detects a new provider-final response from OpenCode's local database on fresh and resumed runs and terminates a stale CLI event stream safely. Database enrichment is best-effort; query failures fall back to the captured CLI stream. A hard timeout (default 30 min, `--timeout` to change) guarantees no job runs forever.
- Exit 0 on the final wait only means the delegate ran and reported; task success is decided by your verification run. Exit 3 means the job is still running. Exit 4 means the turn is incomplete but resumable; use the returned `SESSION:` id instead of treating it as infrastructure failure.
- One delegation at a time per worktree — the delegate edits your working tree. Parallel delegation needs separate git worktrees.

## Output Rules

- Immediately after launching, give the user the JOB id and all returned monitoring commands verbatim so they can follow along.
- Tell the user: what was delegated, the model used, the verification command and its actual result, the session id, and the cost when reported.
- Never claim the delegated task succeeded without showing your own verification output.
