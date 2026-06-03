---
name: report-changes
description: 'Generate a concise report of the code changes made in the current session — what changed and why. Use this skill when asked to report or summarize changes, recap what was done, or write notes for a PR, commit message, or handoff, even when the request does not use the word "report" (for example, when wrapping up a task or handing work off).'
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

## Format examples

Small or medium change — a single flat list:

- Input validation was added to `apply_discount()` to reject percentages outside 0–100.
- Rejecting was chosen over clamping so caller bugs surface instead of being silently corrected.

Large change — short headings grouping related bullets:

Authentication
- A JWT auth module was added to issue and verify access tokens.
- HS256 was chosen over RS256 since the API is a single service with no key-distribution need.

Wiring
- The new routes were registered in the app factory and secrets were moved to environment config.

## Common Mistakes
- Running git commands and re-analyzing the diff from scratch instead of reporting from session memory — this loses the "why" and wastes effort.
- Forcing a large change into one flat list until it becomes unreadable — switch to headed groups.
- Padding a small change with structure or detail it does not need.
