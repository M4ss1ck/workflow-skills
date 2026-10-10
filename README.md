# workflow-skills

A personal collection of agent skills for day-to-day programming workflows. Each skill is a small, self-contained instruction set an AI coding agent loads on demand.

The `skills/` directory is the source of truth and follows the open `SKILL.md` layout used by Claude Code, Codex, Gemini CLI, OpenCode, Antigravity, and similar tools. This repo also includes Claude Code and Codex plugin metadata for agents that prefer plugin installation.

## Skills

| Skill | What it does |
|-------|--------------|
| [report-changes](skills/report-changes/SKILL.md) | Generates a concise, flat-bullet report of the code changes made in a session — for PRs, commit messages, or handoff. |
| [keep-plans-local](skills/keep-plans-local/SKILL.md) | Keeps plans, specs, and working notes as disposable local-only guidance under `docs/plans/`, out of git — overriding skills that would commit them. |
| [follow-plan](skills/follow-plan/SKILL.md) | Executes provided plans exactly, stopping for unresolved decisions instead of improvising or silently deviating. |
| [opencode-subagent](skills/opencode-subagent/SKILL.md) | Delegate bounded, mechanically verifiable implementation work to a constrained OpenCode worker running a cheap model, then verify the result independently. Requires OpenCode 2.x (1.x is no longer supported). |
| [propose-commit-message](skills/propose-commit-message/SKILL.md) | Proposes a Conventional Commits message for the current work (staged changes if any) without committing. Pairs with report-changes at the end of a task. |
| [context-watch](skills/context-watch/SKILL.md) | Reports how large the current Claude Code session's context is. Its companion hook warns once the context passes 200k and 400k tokens (see [Context watch](#context-watch)). |

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
/plugin install context-watch@workflow-skills    # optional: the context-size warning hook alone
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
scripts/install.sh --agent opencode # ~/.config/opencode/skills (+ agent definitions)
scripts/install.sh --all            # every known target
scripts/install.sh --copy           # copy instead of symlink
scripts/install.sh --dir PATH       # custom skills directory
scripts/install.sh --list-agents
scripts/install.sh --no-hooks       # skip every hook (delegation routing and context-watch)
scripts/install.sh --no-context-watch               # skip only the context-watch hook
scripts/install.sh --remove-hooks --agent claude   # remove only the hooks it added
scripts/install.sh --remove-context-watch          # remove only the context-watch hook
```

`--copy` installs one self-contained `opencode-subagent` runtime under `${XDG_DATA_HOME:-~/.local/share}/workflow-skills/`, so the `opencode-delegate` command and the hooks keep working after the clone is moved or deleted. Symlink mode runs the clone directly.

## Native delegation routing

`opencode-subagent` ships hooks that make the supervisor go through the delegation policy before it starts or messages a **native** subagent. Without a recorded routing decision, the native call is denied and becomes a proposal. The supervisor records the facts (`opencode-delegate route record`), the router computes the route from them and the policy (`native`, `opencode`, `local`, `none`, `clarify`), and only a `native` route lets the next matching call through, once. That call runs the proposal exactly as first submitted. The procedure is in [the skill](skills/opencode-subagent/SKILL.md#native-delegation-routing).

| Host | Status | Intercepted calls |
|------|--------|-------------------|
| Claude Code 2.1.270 | Verified live: create denied, continuation denied, allowed control, grant replay | `Agent`, `Task`, `SendMessage` |
| Codex CLI 0.151.0, local hooks | Verified live: create denied, continuation denied, allowed control. Grant replay (`updatedInput`) not yet verified | `collaborationspawn_agent`, `collaborationfollowup_task`, plus documented aliases |
| Codex plugin hooks | Not verified (Codex documents `hooks/hooks.json` for plugins; no live run yet) | same |
| Other hosts, skill-only installs (`--dir`, `npx skills`) | Not enforced | none |

Activation:

- **Local installer:** `scripts/install.sh --agent claude` or `--agent codex` registers the hooks in `~/.claude/settings.json` or `~/.codex/hooks.json` (following a symlinked settings file), using absolute paths for `bash` and `python3`. The hooks run through an owned shim in `${XDG_DATA_HOME:-~/.local/share}/workflow-skills/`: if the entry point breaks (the clone switched to a branch without routing, a moved install), delegation calls are denied and user prompts are not blocked. Unrelated settings and hooks are preserved and reruns replace only these entries. If the workflow-skills plugin is installed, the installer leaves hook registration to the plugin.
- **Plugins:** the Claude Code plugin loads `hooks/hooks.json` (verified live with `--plugin-dir`). The Codex manifest selects `hooks/codex-hooks.json`, which is identical except for `${PLUGIN_ROOT}` and the `codex` host. That path is unverified, and the installer warns when it finds the Codex plugin. Plugin hooks go through the same `route-hook-shim.sh`, from the plugin root, so a broken entry point never blocks a user prompt. If the shim itself is missing (a checkout on a branch from before it existed), the host fails open: the prompt runs and delegation is not routed. The Claude manifest sets no `version`, so Claude Code versions the plugin by commit and `claude plugin update` picks up every push. A plugin does not put `opencode-delegate` on PATH: also run `scripts/install.sh --no-hooks` (or add the command yourself), because the supervisor needs the command to record decisions.
- **Claude Code:** start a new session after installing.
- **Codex:** new or changed hooks are skipped until trusted. Run `/hooks` in Codex and trust the workflow-skills routing entries.
- Check with `opencode-delegate route doctor`: it reports the runtime, whether the PATH command runs the same routing code as the hooks, the policy, and each host's registrations (`not-installed`, `installed-unverified`, or `active-observed` once a hook event from the current runtime has been seen).

Failure behavior. A running hook denies recognized delegation calls when the policy, state or payload is unreadable, and leaves every other tool alone. Hosts still fail open around the hook: Claude Code allows the call if the hook cannot start or times out, and Codex skips untrusted hooks. With `python3` missing, the entry point denies delegation calls. Local work is always possible.

A consumed grant answers the host with `allow` plus the stored input. On Claude Code, `allow` also skips any permission prompt you configured for the `Agent` tool on that one call. On Codex, replaying through `updatedInput` has not been verified live yet. If Codex rejects that response it treats the hook as failed and runs the call with the retry's own arguments, which are still in the same session, worktree and target.

Limits. The router checks that the recorded source words exist and that the record is consistent with the policy; it cannot check that the supervisor classified the work truthfully. For example, recording an OpenCode assignment's work under a new `--assignment` name, or quoting an unrelated later user message as the override, gets past the "OpenCode stays OpenCode" rule. It is a procedure guard, not a security boundary: an agent that can edit its hook or state files, or start another CLI from a shell, can get around it.

## Context watch

Every turn re-reads the whole context, so a long session costs more per turn and recalls less reliably. The `context-watch` hook (Claude Code) reads the session's newest usage row after every tool call (`PostToolUse`, `PostToolUseFailure`) and on every prompt (`UserPromptSubmit`), so a long autonomous turn is caught where it crosses a threshold:

- **WARN, 200k by default:** a notice to you. Crossed after a tool call, the model also gets a line: finish the step it is on, stop, and tell you the size, with no new steps, no handoff and no `/compact` or `/clear` of its own. Crossed when you send a message, it is the notice only.
- **URGE, 400k by default:** the turn stops (`continue: false`). You see the hook's message with the size; what comes next is your call: compact, run your handoff, or tell Claude to continue.
- **Frequency:** each threshold fires once per crossing. Continuing after the stop is not stopped again; a compaction, or a drop well below the threshold, re-arms it. Small dips around a threshold do not re-fire it. Prompts nobody typed (`/loop` ticks, background-agent reports) also trigger it.
- **At a prompt:** a crossing first seen when you send a message cannot stop the turn without discarding that message, so the model is told to raise the size with you before starting the work.
- **Headless runs:** `claude -p` sessions that cross URGE stop too. Raise `CONTEXT_WATCH_URGE` or set `CONTEXT_WATCH_DISABLE=1` for unattended automation.

Thresholds are absolute because quality tracks absolute tokens, not the share of the window: Anthropic's Opus 4.6 system card shows the same 1M-window model dropping from 93 to 76-78 on MRCR v2 8-needle between the 128k-256k and 524k-1M bands. Claude Code's own warning on a 1M window only appears at about 947k. On a 200k-window model Claude Code auto-compacts at about 167k, before WARN, so those sessions rely on its built-in notice.

Install it as its own plugin (`context-watch@workflow-skills`) or through `scripts/install.sh --agent claude`, which registers it by default under the marker `workflow-skills-context-watch`. The two hooks are independent: either can be installed or removed without the other. Configure it through `CONTEXT_WATCH_WARN`, `CONTEXT_WATCH_URGE` and `CONTEXT_WATCH_DISABLE`, set in the environment (or `settings.json` `env`) or in `~/.config/workflow-skills/context-watch.conf`; the environment wins. Subagent prompts and tool calls are ignored. It is Claude Code only: the skill's `status` command reads Claude Code transcripts. Any failure is silent: the hook runs through a shim that always exits 0, so a broken install never blocks a prompt.

Not on OpenCode yet: the OpenCode 2.x plugin API (`setup(api)`) has no stable prompt or context hooks. Upstream lists them as a future migration step.

## Adding a skill

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: copy [templates/skill-template.md](templates/skill-template.md) into `skills/<name>/SKILL.md`, fill it in, and run `scripts/lint-skills.sh`.

## Layout

```
.claude-plugin/    plugin.json + marketplace.json (install metadata)
.codex-plugin/     Codex plugin manifest
.agents/plugins/   repo-scoped Codex marketplace
skills/            one directory per skill, each with a SKILL.md
                   (optionally scripts/ and agents/ it references)
templates/         skeleton for authoring new skills
hooks/             routing hooks: hooks.json (Claude Code plugin), codex-hooks.json (Codex plugin)
plugins/           standalone plugins: context-watch (its scripts/ links to skills/context-watch/scripts)
scripts/           install.sh, lint-skills.sh, and their tests
tests/routing/     sanitized host payload fixtures for the routing tests
tests/evals/       paid behavioral scenarios (delegation-routing/, context-watch/) and recorded results
.github/workflows/ CI that lints every skill
```

## License

[MIT](LICENSE)
