# CLAUDE.md

Claude Code-specific notes for this repository. Read [AGENTS.md](AGENTS.md) first — it holds the conventions that apply to every agent. This file only adds what is specific to Claude Code.

## This repo is a plugin and a marketplace

- `.claude-plugin/plugin.json` defines the `workflow-skills` plugin.
- `.claude-plugin/marketplace.json` lists that plugin with `"source": "./"`, so the repo can be added as a marketplace and installed from itself.

Install and test locally:

```
/plugin marketplace add /home/massick/Trabajo/ai/workflow-skills
/plugin install workflow-skills@workflow-skills
```

After changing a skill, reload it in your session before relying on the new version — skills are read when loaded, not live.

## Editing skills

- Invoke skills with the `Skill` tool; never `Read` a `SKILL.md` to "use" it.
- When adding or changing a skill, start from `templates/SKILL.md` and keep the directory name in sync with the frontmatter `name`.
- Run `bash scripts/lint-skills.sh` before committing.

## Working style

- Keep changes surgical and scoped to the request.
- Keep planning artifacts (`docs/superpowers/specs/`, `docs/superpowers/plans/`) local and uncommitted.
