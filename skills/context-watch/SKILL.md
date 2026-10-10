---
name: context-watch
description: 'Report how large the current Claude Code session''s context is, how it compares to the session start, and how far it is from the context-watch thresholds. Use when the user asks how big the context or session is, whether to /compact or /clear, or invokes /context-watch.'
---

# context-watch

Every turn re-reads the whole context, so a long session costs more per turn and recalls less reliably. This skill measures the context on demand. The companion **context-watch hook** acts automatically: past 200k tokens it asks the model to finish its step and stop, and past 400k it stops the turn.

## Procedure

1. Run the status command from this skill's directory:

   ```bash
   python3 scripts/context_watch.py status
   ```

   It finds this session through `CLAUDE_CODE_SESSION_ID`. Outside Claude Code, pass `--transcript PATH` (a session `.jsonl`) or `--session-id ID`.

2. Relay its output to the user in two or three lines: the size, the ratio to the session start, and where it sits against WARN and URGE.

3. If the context is past WARN, name the options and leave the choice with the user: `/compact` (if their setup has it), their handoff routine, or starting fresh with `/clear`.

## The [context-watch] line

A `[context-watch]` line means the hook measured the context past a threshold. Do what it says:

- **After a tool call (WARN):** finish the step you are on, then stop and tell the user the context size. Do not start another step.
- **With a user message (URGE):** before doing anything for the message, tell the user the size and ask how to proceed.

Either way, do not write a handoff, and never run `/compact` or `/clear` yourself: what happens next is the user's call. If the user says to continue, continue; the hook does not fire again for the same crossing.

## The hook

The automatic warning is a separate install, so the skill works without it:

- **Claude Code plugin:** install `context-watch` from the `workflow-skills` marketplace.
- **Local install:** `scripts/install.sh --agent claude` registers it in `~/.claude/settings.json` (`--no-context-watch` skips it, `--remove-context-watch` removes it).

Behaviour. The hook checks after every tool call (`PostToolUse`, `PostToolUseFailure`) and at every prompt (`UserPromptSubmit`):

- **WARN (default 200k):** a notice to the user. After a tool call, also the `[context-watch]` line telling the model to finish its step and stop; at a prompt, the notice only.
- **URGE (default 400k):** after a tool call, the turn stops (`continue: false`) with the hook's message to the user. Seen first at a prompt, the model is told to ask the user before starting (stopping there would discard the prompt).
- Each threshold fires once per crossing. Compacting, or a drop more than 10% of WARN below a threshold, re-arms it; hovering around a threshold does not re-fire it.
- Subagent prompts and tool calls are ignored. Prompts nobody typed (`/loop` ticks, background-agent reports) do count. Headless `claude -p` runs stop at URGE too; raise the threshold or disable the hook for unattended automation.
- Right after a compaction the size is reported as "just compacted": the exact size is known after the next reply.

Settings come from env vars, or from `~/.config/workflow-skills/context-watch.conf` as `KEY=VALUE` lines; env wins:

| Key | Default | Meaning |
|---|---|---|
| `CONTEXT_WATCH_WARN` | `200k` | first threshold (`250000`, `250k` and `0.25m` all work) |
| `CONTEXT_WATCH_URGE` | `400k` | second threshold (raised to WARN if set lower) |
| `CONTEXT_WATCH_DISABLE` | unset | `1` turns the hook off |

On a 200k-window model, Claude Code auto-compacts at about 167k, before the 200k WARN can fire, so those sessions rely on Claude Code's own "context low" notice. The hook does not run on OpenCode: its 2.x plugin API has no stable prompt or context hooks yet.
