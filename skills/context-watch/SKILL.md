---
name: context-watch
description: 'Report how large the current Claude Code session''s context is, how it compares to the session start, and how far it is from the context-watch thresholds. Use when the user asks how big the context or session is, whether to /compact or /clear, or invokes /context-watch.'
---

# context-watch

Every turn re-reads the whole context, so a long session costs more per turn and recalls less reliably. This skill measures the context on demand. The companion **context-watch hook** warns automatically once the context passes 200k and 400k tokens.

## Procedure

1. Run the status command from this skill's directory:

   ```bash
   python3 scripts/context_watch.py status
   ```

   It finds this session through `CLAUDE_CODE_SESSION_ID`. Outside Claude Code, pass `--transcript PATH` (a session `.jsonl`) or `--session-id ID`.

2. Relay its output to the user in two or three lines: the size, the ratio to the session start, and where it sits against WARN and URGE.

3. If the context is past WARN, name the options and leave the choice with the user: `/compact` (if their setup has it), or saving what matters (memory, repo docs, a handoff note) and starting fresh with `/clear`. The decision belongs to the user, so keep working and let them pick.

## The [context-watch] line

When a turn arrives carrying a `[context-watch]` line, the hook has measured the context past URGE. Keep the current task at full quality and full scope, then mention the size once at the next natural stopping point. Compaction and clearing stay with the user.

## The hook

The automatic warning is a separate install, so the skill works without it:

- **Claude Code plugin:** install `context-watch` from the `workflow-skills` marketplace.
- **Local install:** `scripts/install.sh --agent claude` registers it in `~/.claude/settings.json` (`--no-context-watch` skips it, `--remove-context-watch` removes it).

Behaviour:

- **WARN (default 200k):** a message to the user only. The model never sees it.
- **URGE (default 400k):** the same message, plus the one `[context-watch]` line to the model. Repeats every further 100k.
- Each threshold fires once per crossing. Compacting, or any drop more than 10% of WARN below WARN, re-arms both; hovering around a threshold does not re-fire it.
- Subagent prompts are ignored. Prompts nobody typed (`/loop` ticks, background-agent reports) do count, so a crossing can be announced while you are away; the message stays in the session's history.
- Right after a compaction the size is reported as "just compacted": the exact size is known after the next reply.

Settings come from env vars, or from `~/.config/workflow-skills/context-watch.conf` as `KEY=VALUE` lines; env wins:

| Key | Default | Meaning |
|---|---|---|
| `CONTEXT_WATCH_WARN` | `200k` | first threshold (`250000`, `250k` and `0.25m` all work) |
| `CONTEXT_WATCH_URGE` | `400k` | second threshold (raised to WARN if set lower) |
| `CONTEXT_WATCH_DISABLE` | unset | `1` turns the hook off |

On a 200k-window model, Claude Code auto-compacts at about 167k, before the 200k WARN can fire, so those sessions rely on Claude Code's own "context low" notice. The hook does not run on OpenCode: its 2.x plugin API has no stable prompt or context hooks yet.
