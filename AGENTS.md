# AGENTS.md

Guidance for AI agents working in this repository. This is the single source of truth; `CLAUDE.md` just points here.

## What this repo is

A collection of agent skills. Each skill is a directory under `skills/` containing a `SKILL.md` (and any supporting files the skill references). The repo doubles as a Claude Code plugin and marketplace — see `.claude-plugin/`.

## Anatomy of a skill

Every skill lives at `skills/<name>/SKILL.md` and starts with YAML frontmatter:

- `name` — kebab-case, must match the directory name.
- `description` — one line stating what it does and, critically, the concrete triggers ("Use when: ...") that should activate it. The agent decides whether to load a skill from this field alone, so make the triggers specific.
- `argument-hint` — optional; describe any arguments.

The body holds the instructions the agent follows when the skill is active. Keep it focused: when to use it, the procedure, and the exact output rules.

## Conventions

- One skill = one clear purpose. If a skill tries to do two things, split it.
- The directory name and frontmatter `name` must match.
- Keep skills self-contained: reference supporting files by relative path inside the skill directory.
- Match the tone and structure of existing skills; use `templates/SKILL.md` as the starting point.

## Before you finish

Run the linter — CI runs the same check:

```bash
bash scripts/lint-skills.sh
```

It verifies every skill has a `SKILL.md` beginning with frontmatter that defines a non-empty `name` and `description`.

## Planning artifacts

Design docs and implementation plans stay local under `docs/superpowers/` (git-ignored). Do not commit intermediate planning files; commit finished work.

## Claude Code specifics

This repo is both a Claude Code plugin (`.claude-plugin/plugin.json`) and its own marketplace (`.claude-plugin/marketplace.json`, `"source": "./"`), so it installs from itself:

```
/plugin marketplace add /home/massick/Trabajo/ai/workflow-skills
/plugin install workflow-skills@workflow-skills
```

- Invoke a skill with the `Skill` tool; never `Read` a `SKILL.md` to "use" it.
- Skills are read when loaded, not live — after editing one, reload it before relying on the change.
