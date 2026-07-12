# workflow-skills

A personal collection of agent skills for day-to-day programming workflows. Each skill is a small, self-contained instruction set an AI coding agent loads on demand.

The `skills/` directory is the source of truth and follows the open `SKILL.md` layout used by Claude Code, Codex, Gemini CLI, OpenCode, Antigravity, and similar tools. This repo also includes Claude Code and Codex plugin metadata for agents that prefer plugin installation.

## Skills

| Skill | What it does |
|-------|--------------|
| [report-changes](skills/report-changes/SKILL.md) | Generates a concise, flat-bullet report of the code changes made in a session — for PRs, commit messages, or handoff. |
| [keep-plans-local](skills/keep-plans-local/SKILL.md) | Keeps plans, specs, and working notes as disposable local-only guidance under `docs/plans/`, out of git — overriding skills that would commit them. |
| [claude-subagent](skills/claude-subagent/SKILL.md) | Delegate a verifiable task to a headless Claude Code subagent and verify the result. |
| [codex-subagent](skills/codex-subagent/SKILL.md) | Delegate a verifiable task to a headless Codex subagent and verify the result. |
| [follow-plan](skills/follow-plan/SKILL.md) | Executes provided plans exactly, stopping for unresolved decisions instead of improvising or silently deviating. |
| [opencode-subagent](skills/opencode-subagent/SKILL.md) | Delegate a verifiable task to a headless OpenCode subagent (any provider/model) and verify the result. |
| [propose-commit-message](skills/propose-commit-message/SKILL.md) | Proposes a Conventional Commits message for the current work (staged changes if any) without committing. Pairs with report-changes at the end of a task. |

## Install

### Cross-agent with the skills CLI (recommended)

Use the `skills` CLI when you want the repo installed into every supported agent it detects:

```bash
npx skills add https://github.com/M4ss1ck/workflow-skills.git --skill '*' --all
```

For local development from a clone:

```bash
npx skills add . --skill '*' --all
```

You can target individual agents:

```bash
npx skills add . -g -a claude-code -a codex -a gemini-cli -a opencode --skill '*'
```

### Claude Code plugin

```
/plugin marketplace add https://github.com/M4ss1ck/workflow-skills.git
/plugin install workflow-skills@workflow-skills
```

### Codex plugin

Codex can install this repo as a plugin through the `.codex-plugin/plugin.json` manifest. For local testing, the repo also includes a repo-scoped marketplace at `.agents/plugins/marketplace.json`; restart Codex from this repo and open `/plugins` to browse the `workflow-skills` marketplace.

### Local symlink installer

Clone the repo and run the installer when you want direct symlinks into known agent skill directories. By default it **symlinks** each skill into `~/.claude/skills`, so edits in the repo take effect immediately.

```bash
git clone https://github.com/M4ss1ck/workflow-skills.git
cd workflow-skills
scripts/install.sh                  # ~/.claude/skills (default)
scripts/install.sh --agent codex    # ~/.agents/skills and ~/.codex/skills
scripts/install.sh --agent gemini   # ~/.gemini/skills
scripts/install.sh --agent opencode # ~/.config/opencode/skills
scripts/install.sh --all            # every known target
scripts/install.sh --copy           # copy instead of symlink
scripts/install.sh --dir PATH       # custom skills directory
scripts/install.sh --list-agents
```

## Adding a skill

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: copy [templates/skill-template.md](templates/skill-template.md) into `skills/<name>/SKILL.md`, fill it in, and run `scripts/lint-skills.sh`.

## Layout

```
.claude-plugin/    plugin.json + marketplace.json (install metadata)
.codex-plugin/     Codex plugin manifest
.agents/plugins/   repo-scoped Codex marketplace
skills/            one directory per skill, each with a SKILL.md
templates/         skeleton for authoring new skills
scripts/           install.sh, lint-skills.sh
.github/workflows/ CI that lints every skill
```

## License

[MIT](LICENSE)
