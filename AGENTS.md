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
- `opencode-subagent` uses a Task/Attempt/Event layout (`subagents/task_<id>/` with `task.json`, `events.jsonl`, `attempts/attempt_NNN/`, `verifications/`), implemented in `scripts/orchestration.sh` and driven by `scripts/delegate.sh`. Pre-Task job directories (`subagents/<JOB>/` with `status`, `result.txt`, `raw.jsonl`) may still exist in the shared state root: only directories containing `task.json` are Tasks, and pruning touches only `task_*` and `opencode-*` directories.
- `opencode-subagent` exposes explicit operations (`start / run / retry / resume / status / wait / verify / decide / cancel / list / show / attempts / events / logs / recover / policy`), `--json`, and a delegation policy, alongside the legacy flag forms (`--model / --cwd / --resume / --timeout / --save-default / --wait / --poll-timeout`). `scripts/install.sh` also puts it on PATH as `opencode-delegate`, which is how `SKILL.md` invokes it.
- Native delegation routing lives in `skills/opencode-subagent/scripts/routing.py`, reached only as `delegate.sh route ...` (dispatched before any Task or worker setup). `hooks/hooks.json` (Claude plugin) and `hooks/codex-hooks.json` (Codex plugin, selected in `.codex-plugin/plugin.json`) must stay identical apart from the root variable, the host argument and the Claude-only events. Both call `route-hook-shim.sh` from the plugin root; the installer registers each host's events from that host's file through an owned copy of the shim, marked `# workflow-skills-routing`. Do not add `version` to `.claude-plugin/plugin.json` or its marketplace entry: a pinned version stops GitHub installs from receiving new commits (a test enforces it). Behavioral evals (`tests/evals/delegation-routing/run.py`) are paid live host sessions: run them only deliberately, and never edit `routing.py` or `SKILL.md` while one runs (the runtime identity and skill revision are part of every decision). Routing state is under `$XDG_STATE_HOME/workflow-skills/routing/`, separate from Task directories. Tool names in `WORK_TOOLS` and the `hooks.json` matcher must stay in sync (a test enforces it). Read-only agent types (`Explore`, `Plan`, `claude-code-guide` always, plus `OPENCODE_SUBAGENT_READONLY_AGENTS` patterns) skip routing; it is a name allowlist, not a sandbox. Follow-ups to them pass only by host-assigned agent id (`recipient_kind: "agent"`), never by name: Claude Code allocates and reuses names, so a remembered name can come to mean a writer. The id is learned from a Claude-only `PostToolUse` hook on `Agent|Task` that registers only calls its own PreToolUse exempted (`readonly_uses`, by `tool_use_id`, with the agent type re-checked). `CLAUDE_ONLY_EVENTS` is the one difference between the two hook files' event sets, and `HOOK_EVENTS` lists each host's events for `route doctor`. A PostToolUse hook must never block: the router, the shim and the no-Python fallback answer only a payload whose `"hook_event_name"` key is `PreToolUse`, matched as the key, never the bare word. Unreadable input is the one exception: it is denied whatever the event, which cannot block a PostToolUse.
- `opencode-subagent` has two roles, one OpenCode agent each: `worker` (`agents/workflow-worker.md`, edits, no network) and `researcher` (`agents/workflow-researcher.md`, read-only bash allowlist, `websearch`/`webfetch`, no edits, no `.env`). `delegate.sh --role` picks one; the Task stores it as `task.json .agent` and `retry`/`resume` reuse it. OpenCode 2.x checks each command of a compound line (`;`, `&&`, `|`) on its own and the last matching rule wins, so the researcher's allowlist starts with `"*": deny`, anchors each allowed command with a trailing space (`"git diff *"`, so `git difftool` stays out), and ends with its denies. `scripts/test-subagent-scripts.sh` replays a must-allow / must-deny corpus against those rules: extend it when you change them. Routing sends research and review to the researcher by default and never routes a review `local`.
- A skill may ship OpenCode agent definitions in `skills/<name>/agents/*.md`. `scripts/install.sh --agent opencode` installs them into `~/.config/opencode/agent/`, and `opencode-subagent/scripts/delegate.sh` re-syncs its own before every launch. OpenCode 2.x refuses an unknown `--agent NAME` (1.x fell back to the unconstrained default agent), so the definition must be on disk before launching.
- `opencode-subagent` supports OpenCode 2.x only (version-gated in `delegate.sh` preflight). It launches `opencode run --standalone` (no `--dir`: the runner `cd`s into the Task's tree), reads the session back with `opencode session export --standalone`, and falls back to the 2.x JSON stream, which has no `step_finish` after the closing text. Do not reintroduce `opencode db` or `--dir`; the test stub in `scripts/test-subagent-scripts.sh` models the 2.x CLI.

- `context-watch` is a Claude Code hook on `PostToolUse`, `PostToolUseFailure` and `UserPromptSubmit`. After a tool call, WARN tells the model to finish its step and stop, and URGE stops the turn with `continue: false` (Claude Code drops every other field of a halting output, so URGE carries only `stopReason`). Each threshold fires once per crossing. Its one core is `skills/context-watch/scripts/context_watch.py`, reached only through `context-watch-shim.sh`, which always exits 0 (exit 2 from this event blocks the user's prompt). `plugins/context-watch/` is a second plugin in the same marketplace that ships the hook and nothing else. Its `scripts` is a symlink to the skill's scripts, which plugin installs copy through (verified on Claude Code 2.1.289). Keep the skill out of `plugins/`, or it loads twice. The installer registers it under the marker `workflow-skills-context-watch`, independent of the routing marker. Context size is the newest non-synthetic, non-sidechain assistant usage row. A newer `compact_boundary` means "just compacted": its `postTokens` counts only the summary, not the system prompt and tools, so it is never reported as the size. Ownership in `merge_hooks` is the trailing `# marker` comment, never a substring: a checkout path can contain either marker.

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

Run the routing tests when changing `skills/opencode-subagent/scripts/routing.py`, `route-hook-shim.sh`, `hooks/*.json`, the `route` dispatch in `delegate.sh`, or the opencode-subagent `SKILL.md` routing section (deterministic, no model calls, under 2s):

```bash
python3 scripts/test-routing.py
```

Run the context-watch tests when changing anything under `skills/context-watch/` or `plugins/context-watch/` (deterministic, under 1s):

```bash
python3 scripts/test-context-watch.py
```

`tests/evals/context-watch/run.py` is the paid behavioral eval: live Claude sessions checking that a tool call crossing URGE stops the turn, and that WARN makes the model stop after its current step. Run it only deliberately.

## Planning artifacts

Design docs and implementation plans stay local under `docs/plans/` (git-ignored). Do not commit intermediate planning files; commit finished work.

## Claude Code specifics

This repo is both a Claude Code plugin (`.claude-plugin/plugin.json`) and its own marketplace (`.claude-plugin/marketplace.json`, `"source": "./"`), so it installs from itself:

```
/plugin marketplace add /path/to/workflow-skills
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
