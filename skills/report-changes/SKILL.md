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
1. Review all files changed in the current session (use git diff or session context)
2. Identify the thought process: why each change was made, what drove decisions
3. Produce a bullet list following the output rules below

## Output Rules
- Use a flat bullet list only — no bold text, no section headers, no nested lists
- Write in passive voice ("X was added", "Y was updated")
- Keep each bullet to one simple sentence
- Order bullets by logical flow (setup/context first, then implementation, then wiring)
- Include both what was changed and why, but stay concise
