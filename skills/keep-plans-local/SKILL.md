---
name: keep-plans-local
description: 'Keep planning artifacts as disposable local-only guidance and out of git. Use when writing or saving a plan, spec, design doc, or working notes; when another skill (such as brainstorming or writing-plans) would create or commit such a document; or when staging, committing, pushing, or opening a PR.'
---

# Keep Plans Local

## Overview
Plans, specs, design docs, and working notes are disposable local guidance — useful while implementing, stale once the work is done. They belong on disk, never in git. Create and revise them freely; just keep them out of commits so the repo holds only what matters.

## Procedure
1. Save every plan, spec, design doc, or working-notes file under `docs/plans/`.
2. Ensure `docs/plans/.gitignore` exists with exactly these two lines:
   ```
   *.md
   .gitignore
   ```
   Create it if missing. This ignores every plan and the ignore file itself, so the whole directory stays out of git automatically — even under `git add -A`. This is the guard that makes exclusion reliable; do not skip it.
3. Never stage or commit files under `docs/plans/`. Commit only the real deliverable (code and user-facing docs).
4. Reuse and rewrite plans locally as much as you want; expect them to go stale and be discarded.

## This overrides other skills
When another skill's steps say to commit a design doc or plan — brainstorming ("commit the design document"), writing-plans, and similar — this rule wins: the plan stays local. Following another skill is never a reason to commit a plan.

## Explicit request
If the user explicitly asks to commit a specific plan, comply with no friction: `git add -f <path>` (it is gitignored) and commit it.

## Not a planning artifact
README, CONTRIBUTING, user-facing docs, changelogs, and ADRs you have decided to keep are deliverables — commit them normally. Only working/intermediate artifacts go under `docs/plans/`.

## Common Mistakes
- Leaving a plan untracked without the `docs/plans/.gitignore` guard — a later `git add -A` or another skill sweeps it into the commit.
- Putting the guard at the repo root instead of inside `docs/plans/`; the self-ignoring local file is the point.
- Over-excluding real deliverables (README, CONTRIBUTING) as if they were plans.
- Deleting plans to "keep things clean" — keep them locally; they are free and often useful mid-task.
