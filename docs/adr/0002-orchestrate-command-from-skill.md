# `/orchestrate` is a skill with a generated OpenCode command

Claude Code, Codex and OpenCode all consume `SKILL.md`, but only Claude Code and Codex turn a skill into an explicit invocation directly. OpenCode keeps commands in a separate registry under its global config directory. A second hand-written command body would drift from the skill, so `skills/orchestrate/SKILL.md` is the single source: Claude Code exposes it as `/orchestrate`, Codex through its skill selector, and `scripts/install.sh --agent opencode` generates `<config>/commands/orchestrate.md` with OpenCode frontmatter (`description` only) and the skill body unchanged. The generated file carries a marker comment and the installer refuses to overwrite a file without it. `OPENCODE_CONFIG_DIR` wins over `XDG_CONFIG_HOME/opencode`, which wins over `~/.config/opencode`; the installer and `delegate.sh` resolve that ladder the same way, so the command and the worker agent sit where OpenCode reads them. Codex custom prompts are deprecated and local-only, so no prompt file ships for Codex.

## Consequences

- Editing the skill requires re-running `scripts/install.sh --agent opencode`; the generated command is a copy, not a symlink.
- `scripts/test-install.sh` asserts exact body equality, the YAML shape, no unexpected `$` expansion, no shell block, the XDG and `OPENCODE_CONFIG_DIR` paths, and the foreign-file guard.
- A description the installer cannot copy as valid YAML stops the install instead of leaving a stale command behind.
- `delegate.sh` resolves the agent directory with the same config ladder, covered by `scripts/test-subagent-scripts.sh`.
