---
name: claude-subagent
description: 'Delegate a self-contained, mechanically verifiable task to a Claude Code subagent in headless mode and verify the result yourself. Use only when the user explicitly asks to delegate to Claude (e.g. "delegate this to claude", "ask claude to review this", "/claude-subagent"). This runs a paid external CLI — never invoke it proactively or on your own cost judgment. Not for native subagents: if you are already Claude Code, a generic "use a subagent" means your built-in Agent tool, not this skill.'
argument-hint: 'Required: the task to delegate. Optional: model (defaults to the saved default in subagents.conf, then the user''s claude config) and permission mode.'
---

# Claude Subagent

Delegate work to `claude -p` (headless Claude Code). Two economic modes: escalate hard reasoning to a strong Claude model from a cheaper session, or isolate a heavy loop in a cheap Claude model (pass `--model claude-haiku-4-5`). Either way the handoff contract below is mandatory — the savings die with vague specs.

## When to Use

- The user explicitly asked to delegate to Claude. Their request is sufficient authorization — they decide when the spend is worth it, so support arbitrary delegations without second-guessing them.
- Delegation pays off most when the task is self-contained and success is mechanically verifiable (tests, linter, build) — or, for review/analysis tasks, yields a concrete inspectable deliverable (e.g. "a list of findings with file:line references"). If the request is exploratory or lacks a checkable outcome, say so in one line, then proceed as asked.

## When NOT to Use

- You are already Claude Code and the request says "subagent" or "claude subagent" generically. That means your native Agent tool, not this skill. Use this skill only when a separate headless `claude` process is explicitly the point: cross-provider orchestration from another host, or the user naming this skill.

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
   The default permission mode is `acceptEdits` (file edits allowed, shell commands denied). If the delegate must run its own verification commands, pass `--permission-mode bypassPermissions` — only in a trusted, disposable environment.
   This returns immediately with a `JOB:` id and `WATCH:` / `STATUS:` / `RESULT:` lines.
5. Relay the WATCH, STATUS, and RESULT commands to the user right away, before waiting — those are how they follow the subagent's work live.
6. Wait with bounded polls: `bash scripts/delegate.sh --wait <JOB> --poll-timeout 300`, setting your shell tool's own timeout above 300 s. Exit 3 means still running — poll again. Never abandon a running job silently; if you must stop, give the user the job id and the watch commands.
7. When the wait prints the result, read `SESSION:` (keep it for follow-ups), `COST:` (real USD from claude's JSON), `EXIT:`, and the report after `--- REPORT ---`.
8. Re-run the definition-of-done command yourself when one exists. Never accept the report's success claim alone.
9. If verification fails, resume — do not re-delegate from scratch:
   `bash scripts/delegate.sh --resume <SESSION> "fix: <specific correction>"`
   That launches a new job; follow it the same way. After two failed resumes, take the task over in-context.

## Constraints

- Requires `claude` and `jq` on PATH — check with `scripts/install.sh --doctor` from the workflow-skills repo. A nonzero launch exit is an infrastructure failure (CLI missing, auth, crash) — inspect the output; do not blind-retry.
- The subagent runs detached: job state lives under `~/.local/state/workflow-skills/subagents/<JOB>/` (`raw.jsonl`, `stderr.log`, `status`, `result.txt`) and survives your session. A hard timeout (default 30 min, `--timeout` to change) guarantees no job runs forever.
- Exit 0 on the final wait only means the delegate ran and reported; task success is decided by your verification run. Exit 3 from `--wait` is not a failure — the job is still running.
- One delegation at a time per worktree — the delegate edits your working tree. Parallel delegation needs separate git worktrees.
- Nested Claude Code sessions are steered toward a private scratchpad for "temporary" files. Name deliverable files by absolute path in the spec, or the delegate may write them to its scratchpad instead of your worktree.

## Output Rules

- Immediately after launching, give the user the JOB id and the WATCH/STATUS/RESULT commands verbatim so they can follow along.
- Tell the user: what was delegated, the model used, the verification command and its actual result, the session id, and the reported cost in USD.
- Never claim the delegated task succeeded without showing your own verification output.
