---
name: codex-subagent
description: 'Delegate a self-contained, mechanically verifiable task to a Codex subagent in headless mode and verify the result yourself. Use only when the user explicitly asks to delegate to Codex (e.g. "delegate this to codex", "get codex''s opinion on this", "/codex-subagent"). This runs a paid external CLI — never invoke it proactively or on your own cost judgment. Not for native subagents: if you are already Codex, a generic "use a subagent" means your own agent mechanisms, not this skill.'
argument-hint: 'Required: the task to delegate. Optional: model (defaults to the saved default in subagents.conf, then the user''s codex config).'
---

# Codex Subagent

Delegate work to `codex exec` (headless Codex CLI). Typical use: a second strong model for hard tasks, or cross-checking another model's work. The handoff contract below is mandatory — the savings die with vague specs.

## When to Use

- The user explicitly asked to delegate to Codex. Their request is sufficient authorization — they decide when the spend is worth it, so support arbitrary delegations without second-guessing them.
- Delegation pays off most when the task is self-contained and success is mechanically verifiable (tests, linter, build) — or, for review/analysis tasks, yields a concrete inspectable deliverable (e.g. "a list of findings with file:line references"). If the request is exploratory or lacks a checkable outcome, say so in one line, then proceed as asked.

## When NOT to Use

- You are already Codex and the request says "subagent" or "codex subagent" generically. That means Codex's own native agent mechanisms, not this skill. Use this skill only when a separate headless `codex` process is explicitly the point: cross-provider orchestration from another host, or the user naming this skill.

## Handoff Contract

The delegation spec MUST contain, in this order:
1. **Objective** — one sentence.
2. **Context** — the specific file paths and constraints that matter. No repo tour; the delegate can read files itself.
3. **Definition of done** — an exact command and its expected outcome (or the exact deliverable for analysis tasks).
4. **Boundaries** — files/areas not to touch, plus verbatim: "Do not delegate further; execute directly."
5. **Report format** — verbatim: "End with a report: files changed, verification output, open concerns."

## Procedure

1. If the task lacks a concrete definition of done, warn the user in one line and continue — the delegation decision is theirs.
2. Resolve the model: if the user named one, pass it exactly via `--model M` — never substitute or "upgrade" their choice — and add `--save-default` the first time so it becomes their saved default (tell them it is now saved). If they named none, omit `--model`: the saved default from `~/.config/workflow-skills/subagents.conf` applies, or else the delegate's own configured default.
3. Write the spec per the Handoff Contract.
4. Launch (path relative to this skill's directory):
   `bash scripts/delegate.sh [--model M] [--cwd DIR] [--timeout SECS] "<spec>"`
   The delegate runs with Codex's `workspace-write` sandbox: it can edit files and run commands in the worktree, but nested network access depends on the user's `~/.codex/config.toml` (`[sandbox_workspace_write] network_access = true` — the installer can set this with consent).
   This returns immediately with a `JOB:` id and `WATCH:` / `STATUS:` / `PROGRESS:` / `PROVIDER_REPORT:` / `RESULT:` lines.
5. Relay every returned monitoring command to the user right away, before waiting. `PROGRESS` exposes the raw provider stream; `PROVIDER_REPORT` stores the final response separately.
6. Wait with bounded polls: `bash scripts/delegate.sh --wait <JOB> --poll-timeout 300`, setting your shell tool's own timeout above 300 s. Exit 3 means still running — poll again. Never abandon a running job silently; if you must stop, give the user the job id and the watch commands.
7. When the wait prints the result, read `SESSION:` (keep it for follow-ups), `COST:` (token usage), `EXIT:`, and the report after `--- REPORT ---`.
8. Re-run the definition-of-done command yourself when one exists. Never accept the report's success claim alone.
9. If verification fails, resume — do not re-delegate from scratch:
   `bash scripts/delegate.sh --resume <SESSION> "fix: <specific correction>"`
   That launches a new job; follow it the same way. After two failed resumes, take the task over in-context.

## Constraints

- Requires `codex` and `jq` on PATH — check with `scripts/install.sh --doctor` from the workflow-skills repo. A nonzero launch exit is an infrastructure failure (CLI missing, auth, crash) — inspect the output; do not blind-retry.
- The subagent runs detached: job state lives under `~/.local/state/workflow-skills/subagents/<JOB>/` (`raw.jsonl`, `provider-report.txt`, `stderr.log`, `status`, `result.txt`) and survives your session. A hard timeout (default 30 min, `--timeout` to change) guarantees no job runs forever.
- Exit 0 on the final wait only means the delegate ran and reported; task success is decided by your verification run. Exit 3 from `--wait` is not a failure — the job is still running.
- One delegation at a time per worktree — the delegate edits your working tree. Parallel delegation needs separate git worktrees.

## Output Rules

- Immediately after launching, give the user the JOB id and all returned monitoring commands verbatim so they can follow along.
- Tell the user: what was delegated, the model used, the verification command and its actual result, the session id, and token usage when reported.
- Never claim the delegated task succeeded without showing your own verification output.
