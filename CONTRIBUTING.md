# Contributing

This repo collects small, single-purpose agent skills. Here is how to add one.

## Add a skill

1. Create the directory and copy the template:

   ```bash
   mkdir -p skills/<name>
   cp templates/skill-template.md skills/<name>/SKILL.md
   ```

2. Fill in `skills/<name>/SKILL.md`:
   - `name` in the frontmatter must equal `<name>` (the directory name), kebab-case.
   - Write a `description` that states what the skill does **and** the concrete triggers under "Use when: ...". The agent loads a skill based on this line alone, so be specific.
   - Replace the body sections (When to Use, Procedure, Output Rules) with the skill's actual instructions.

3. If the skill needs supporting files (scripts, templates, examples), put them inside `skills/<name>/` and reference them by relative path.

## Validate

Run the linter before committing — CI runs the same check on every push and PR:

```bash
bash scripts/lint-skills.sh
```

It fails if any skill is missing a `SKILL.md`, doesn't start with frontmatter, or lacks a non-empty `name` or `description`.

## Principles

- **One purpose per skill.** If it does two things, make two skills.
- **Concrete triggers.** Vague descriptions mean the skill never activates (or activates wrongly).
- **Self-contained.** A skill should make sense without reading the rest of the repo.
- **Match existing style.** Read a couple of existing skills before writing a new one.

## Commits

- Keep changes scoped; commit finished skills, not work-in-progress scaffolding.
- Don't commit planning artifacts — `docs/plans/` is git-ignored.
