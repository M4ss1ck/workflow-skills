---
name: report-changes
description: 'Generate a report of code changes made in the current session. Use when: asked to make a report, report changes, summarize work, recap what was done, or document modifications for handoff.'
argument-hint: 'Optional: scope or format preferences for the report'
---

# Report Changes

## When to Use
- After completing a set of code changes
- When asked to recap or list what was done
- When generating notes for a PR, commit message, or handoff

## Procedure
1. Draw on the current session as the primary source: what was changed and, just as importantly, why — the decisions made, problems hit, and alternatives rejected.
2. Use `git diff`/`git status` only to confirm the file list and catch anything the session missed. Do not re-review the diff as if seeing it for the first time or re-derive intent from the code; the reasoning already lives in the session.
3. Choose the format that fits the size of the change (see Output Rules), then write the report.

## Output Rules
- Capture both what changed and why, giving the reasoning equal weight to the change itself.
- Write in passive voice ("X was added", "Y was updated"), one idea per bullet, concise and correct.
- Order by logical flow: setup/context first, then implementation, then wiring.
- Small or medium changes: a single flat bullet list — no headings, no nesting.
- Large changes: group bullets under short headings so the report stays scannable. Add structure only where it aids clarity, never at the expense of simplicity or conciseness.

## Common Mistakes
- Running git commands and re-analyzing the diff from scratch instead of reporting from session memory — this loses the "why" and wastes effort.
- Forcing a large change into one flat list until it becomes unreadable — switch to headed groups.
- Padding a small change with structure or detail it does not need.
