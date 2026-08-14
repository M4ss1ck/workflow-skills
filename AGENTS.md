# AGENTS.md

Guidance for AI agents working in this repository. This is the single source of truth; `CLAUDE.md` just points here.

## What this repo is

A collection of agent skills. Each skill is a directory under `skills/` containing a `SKILL.md` (and any supporting files the skill references). The repo is meant to stay portable across skills-compatible agents: Claude Code, Codex, Gemini CLI, OpenCode, Antigravity, and similar tools.

The repo also includes tool-specific distribution metadata:

- Claude Code plugin and marketplace metadata under `.claude-plugin/`.
- Codex plugin metadata under `.codex-plugin/`.
- Repo-scoped Codex marketplace metadata under `.agents/plugins/`.

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
- Match the tone and structure of existing skills; use `templates/skill-template.md` as the starting point.
- The three `*-subagent` skills share a core `delegate.sh` flag interface (`--model / --cwd / --resume / --timeout / --save-default / --wait / --poll-timeout`) by convention, not by shared code. When changing any of those, apply the same edit to all three.
- `claude-subagent` and `codex-subagent` still use the flat job-state layout (`subagents/<JOB>/` with `status`, `result.txt`, `raw.jsonl`). `opencode-subagent` has moved to a Task/Attempt/Event layout (`subagents/task_<id>/` with `task.json`, `events.jsonl`, `attempts/attempt_NNN/`, `verifications/`), implemented in `scripts/orchestration.sh` and driven by `scripts/delegate.sh`. The two layouts share the state root and coexist: only directories containing `task.json` are Tasks, and only opencode's pruning touches `task_*` and `opencode-*` directories.
- `opencode-subagent` additionally exposes explicit operations (`start / run / retry / resume / status / wait / verify / decide / cancel / list / show / attempts / events / logs / recover / policy`), `--json`, and a delegation policy. Those are deliberately not mirrored in the other two yet; the legacy flag forms above still work identically everywhere.
- A skill may ship OpenCode agent definitions in `skills/<name>/agents/*.md`. `scripts/install.sh --agent opencode` installs them into `~/.config/opencode/agent/`, and `opencode-subagent/scripts/delegate.sh` re-syncs its own before every launch. `opencode run --agent NAME` falls back to the unconstrained default agent with only a warning when the name is unknown, so the definition must be on disk before launching.

## Before you finish

Run the linter — CI runs the same check:

```bash
bash scripts/lint-skills.sh
```

It verifies every skill has a `SKILL.md` beginning with frontmatter that defines a non-empty `name` and `description`.

Run the installer tests when changing `scripts/install.sh`:

```bash
bash scripts/test-install.sh
```

Run the linter tests when changing `scripts/lint-skills.sh`:

```bash
bash scripts/test-lint-skills.sh
```

Run the subagent script tests when changing any `skills/*-subagent/scripts/delegate.sh`:

```bash
bash scripts/test-subagent-scripts.sh
```

## Planning artifacts

Design docs and implementation plans stay local under `docs/plans/` (git-ignored). Do not commit intermediate planning files; commit finished work.

## Claude Code specifics

This repo is both a Claude Code plugin (`.claude-plugin/plugin.json`) and its own marketplace (`.claude-plugin/marketplace.json`, `"source": "./"`), so it installs from itself:

```
/plugin marketplace add /home/massick/Trabajo/ai/workflow-skills
/plugin install workflow-skills@workflow-skills
```

- Invoke a skill with the `Skill` tool; never `Read` a `SKILL.md` to "use" it.
- Skills are read when loaded, not live — after editing one, reload it before relying on the change.

## Codex specifics

Codex reads the plugin manifest at `.codex-plugin/plugin.json`, which points at `./skills/`. It can also discover the repo-scoped marketplace at `.agents/plugins/marketplace.json` when Codex is launched from this repository.

Codex local skill discovery also supports symlinked skills. Use:

```bash
bash scripts/install.sh --agent codex
```

That installs into both `~/.agents/skills` and `~/.codex/skills` for broad compatibility.

## Cross-agent installer

Prefer the `skills` CLI for public cross-agent install instructions:

```bash
npx skills add https://github.com/M4ss1ck/workflow-skills.git --skill '*' --all
```

Keep `scripts/install.sh` as the local development helper for direct symlinks or copies. Use `bash scripts/install.sh --list-agents` to see supported local targets.
