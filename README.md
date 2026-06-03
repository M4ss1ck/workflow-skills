# workflow-skills

A personal collection of [agent skills](https://docs.claude.com/en/docs/claude-code/skills) for day-to-day programming workflows. Each skill is a small, self-contained instruction set an AI coding agent loads on demand.

This repo is both a Claude Code **plugin** and its own **marketplace**, so it installs through the official `/plugin` flow. The same `skills/` directory is portable to other agents (Codex, Gemini) that read skills from a directory.

## Skills

| Skill | What it does |
|-------|--------------|
| [report-changes](skills/report-changes/SKILL.md) | Generates a concise, flat-bullet report of the code changes made in a session — for PRs, commit messages, or handoff. |
| [keep-plans-local](skills/keep-plans-local/SKILL.md) | Keeps plans, specs, and working notes as disposable local-only guidance under `docs/plans/`, out of git — overriding skills that would commit them. |

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add <this-repo-url>
/plugin install workflow-skills@workflow-skills
```

### Manual / cross-agent

Clone the repo and run the installer. By default it **symlinks** each skill into `~/.claude/skills`, so edits in the repo take effect immediately.

```bash
git clone <this-repo-url>
cd workflow-skills
scripts/install.sh            # ~/.claude/skills (default)
scripts/install.sh --agents   # ~/.agents/skills (Codex / agent-agnostic)
scripts/install.sh --copy     # copy instead of symlink
scripts/install.sh --dir PATH # custom skills directory
```

## Adding a skill

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: copy [templates/SKILL.md](templates/SKILL.md) into `skills/<name>/SKILL.md`, fill it in, and run `scripts/lint-skills.sh`.

## Layout

```
.claude-plugin/    plugin.json + marketplace.json (install metadata)
skills/            one directory per skill, each with a SKILL.md
templates/         skeleton for authoring new skills
scripts/           install.sh, lint-skills.sh
.github/workflows/ CI that lints every skill
```

## License

[MIT](LICENSE)
