---
name: opencode-subagent
description: 'Delegate a self-contained, mechanically verifiable task to an OpenCode subagent (any provider/model, typically a cheap one) and verify the result yourself. Use only when the user explicitly asks to delegate to OpenCode (e.g. "delegate this to opencode", "have opencode implement this", "/opencode-subagent"). This runs a paid external CLI — never invoke it proactively or on your own cost judgment.'
argument-hint: 'Required: the task to delegate. Optional: model as provider/model (defaults to the user''s opencode config).'
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
2. If the user named a model, pass it exactly via `--model provider/model`; never substitute or "upgrade" their choice. If they named none, omit `--model` so the delegate's configured default applies.
3. Write the spec per the Handoff Contract.
4. Run (path relative to this skill's directory):
   `bash scripts/delegate.sh [--model provider/model] [--cwd DIR] "<spec>"`
5. Read the normalized output: `SESSION:` (keep it for follow-ups), `COST:`, `EXIT:`, and the report after `--- REPORT ---`.
6. Re-run the definition-of-done command yourself when one exists. Never accept the report's success claim alone.
7. If verification fails, resume — do not re-delegate from scratch:
   `bash scripts/delegate.sh --resume <SESSION> "fix: <specific correction>"`
   After two failed resumes, take the task over in-context.

## Constraints

- Requires `opencode` and `jq` on PATH. A nonzero script exit is an infrastructure failure (CLI missing, auth, crash) — inspect the output; do not blind-retry.
- Exit 0 only means the delegate ran and reported; task success is decided by your verification run.
- One delegation at a time per worktree — the delegate edits your working tree. Parallel delegation needs separate git worktrees.

## Output Rules

- Tell the user: what was delegated, the verification command and its actual result, the session id, and the cost when reported.
- Never claim the delegated task succeeded without showing your own verification output.
