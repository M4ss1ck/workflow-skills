---
name: claude-subagent
description: 'Delegate a self-contained, mechanically verifiable task to a Claude Code subagent in headless mode and verify the result yourself. Use only when the user explicitly asks to delegate to Claude (e.g. "delegate this to claude", "ask claude to review this", "/claude-subagent"). This runs a paid external CLI — never invoke it proactively or on your own cost judgment. Not for native subagents: if you are already Claude Code, a generic "use a subagent" means your built-in Agent tool, not this skill.'
argument-hint: 'Required: the task to delegate. Optional: model (e.g. claude-haiku-4-5 for cheap, default for strong) and permission mode.'
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
2. If the user named a model, pass it exactly via `--model M`; never substitute or "upgrade" their choice. If they named none, omit `--model` so the delegate's configured default applies.
3. Write the spec per the Handoff Contract.
4. Run (path relative to this skill's directory):
   `bash scripts/delegate.sh [--model M] [--cwd DIR] "<spec>"`
   The default permission mode is `acceptEdits` (file edits allowed, shell commands denied). If the delegate must run its own verification commands, pass `--permission-mode bypassPermissions` — only in a trusted, disposable environment.
5. Read the normalized output: `SESSION:` (keep it for follow-ups), `COST:` (real USD from claude's JSON), `EXIT:`, and the report after `--- REPORT ---`.
6. Re-run the definition-of-done command yourself when one exists. Never accept the report's success claim alone.
7. If verification fails, resume — do not re-delegate from scratch:
   `bash scripts/delegate.sh --resume <SESSION> "fix: <specific correction>"`
   After two failed resumes, take the task over in-context.

## Constraints

- Requires `claude` and `jq` on PATH. A nonzero script exit is an infrastructure failure (CLI missing, auth, crash) — inspect the output; do not blind-retry.
- Exit 0 only means the delegate ran and reported; task success is decided by your verification run.
- One delegation at a time per worktree — the delegate edits your working tree. Parallel delegation needs separate git worktrees.
- Nested Claude Code sessions are steered toward a private scratchpad for "temporary" files. Name deliverable files by absolute path in the spec, or the delegate may write them to its scratchpad instead of your worktree.

## Output Rules

- Tell the user: what was delegated, the verification command and its actual result, the session id, and the reported cost in USD.
- Never claim the delegated task succeeded without showing your own verification output.
