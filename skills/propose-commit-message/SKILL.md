---
name: propose-commit-message
description: 'Propose a Conventional Commits message for the current work, without committing. Use when work on a task is done, or when asked to draft, propose, suggest, or write a commit message. Pairs with report-changes at the end of a task.'
---

# Propose Commit Message

## Overview
Propose one well-formed commit message so the user can commit on their own terms. You never commit — the user chooses when and what. Use the Conventional Commits format.

## Procedure
1. Determine the change set:
   - If anything is staged, describe exactly the staged files (`git diff --cached`).
   - Otherwise describe the session's logical change (`git status` / `git diff` to confirm the files).
2. Source the *why* from this session — the decisions and reasoning — not only what the diff shows (same session-first sourcing as report-changes).
3. Write one Conventional Commit and present it in a copy-paste code block. Do not run `git commit` or `git add`, and do not stage anything.

## Conventional Commits format
```
type(optional-scope): imperative summary

Body explaining what changed and why, wrapped ~72 cols. Optional.

BREAKING CHANGE: description   # footer, only if applicable
Refs: #123                     # footer, only if applicable
```
- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`.
- Subject: imperative mood, no trailing period, kept to ~72 characters.

## One concern per commit
A commit is one logical change. If the change set spans unrelated concerns (e.g. a bugfix plus an unrelated docs tweak), do not cram them into one message. Propose the message for the primary or staged concern and say the rest belong in their own commits.

## Pairing at the end of a task
When wrapping up a task, this pairs with report-changes: give the change report first, then the proposed commit message. report-changes recaps the work; this skill distills it into a commit.

## Boundaries
- Never run `git commit` / `git add` — propose text only; the user commits.
- Don't add `Co-Authored-By` or other agent trailers; those belong to the actual commit step.
- The subject is imperative ("add", "fix") — deliberately different from report-changes' passive voice, because that is the commit convention.

## Common Mistakes
- Omitting the Conventional Commits type prefix — a plain "Fix X" subject is not a Conventional Commit.
- Describing unstaged or unrelated files as part of a commit that will not include them.
- Bundling unrelated concerns into one message instead of suggesting separate commits.
- Committing or staging on the user's behalf.
