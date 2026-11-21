---
name: context-watch
description: 'Report how large the current Claude Code session''s context is, how it compares to the session start, and how far it is from the context-watch thresholds. Use when the user asks how big the context or session is, whether to /compact or /clear, or invokes /context-watch.'
---

# context-watch

Every turn re-reads the whole context, so a long session costs more per turn and recalls less reliably. This skill measures the context on demand. The companion **context-watch hook** acts automatically: past 200k tokens it asks the model to finish its step and stop, past 400k to stop at once, and each time to hand the user a prompt for a new session.

## Procedure

1. Run the status command from this skill's directory:

   ```bash
   python3 scripts/context_watch.py status
   ```

   It finds this session through `CLAUDE_CODE_SESSION_ID`. Outside Claude Code, pass `--transcript PATH` (a session `.jsonl`) or `--session-id ID`.

2. Relay its output to the user in two or three lines: the size, the ratio to the session start, and where it sits against WARN and URGE.

3. If the context is past WARN, end with a handoff prompt (below), written to the `handoff file` path the command printed. Whether to switch sessions stays the user's call.

## The [context-watch] line

A `[context-watch]` line means the hook measured the context past a threshold. Do what it says:

- **After a tool call, WARN:** finish the step you are on, then stop and tell the user the context size. Do not start another step.
- **After a tool call, URGE:** stop at the next point where stopping leaves nothing broken, even mid-step, and say what is left undone.
- **With a user message, WARN:** handle the message, then tell the user the size.
- **With a user message, URGE:** before doing anything for the message, tell the user the size and ask how to proceed.

Every case ends with a handoff prompt. If the user said to keep going regardless of context, or this is a `/goal` or `/loop` run, write the handoff anyway, give the prompt, and carry on. If the user says to continue, continue; the hook does not fire again for the same crossing.

## The handoff prompt

A **handoff prompt** is text the user can paste unmodified into a new session to continue the work.

1. Once you stop, write the **handoff file** with the Write tool to the path the line (or `status`) names, overwriting any earlier one. Write it for a reader with none of this session's history:
   - the user's goal, in their words
   - what is done
   - what is in progress, and the exact next step
   - decisions made, and why
   - branch, files touched, and commands that check the work
   - open questions

   Point to paths instead of pasting their contents.
2. End the message with the prompt in a fenced block: `Read <path> and continue the work described there.`
3. If the write fails (permission denied, read-only path), put the whole handoff in the fenced block instead, so it works pasted as-is.

## The hook

The automatic warning is a separate install, so the skill works without it:

- **Claude Code plugin:** install `context-watch` from the `workflow-skills` marketplace.
- **Local install:** `scripts/install.sh --agent claude` registers it in `~/.claude/settings.json` (`--no-context-watch` skips it, `--remove-context-watch` removes it).

Behaviour. The hook checks after every tool call (`PostToolUse`, `PostToolUseFailure`) and at every prompt (`UserPromptSubmit`):

- **WARN (default 200k):** a notice to the user and the `[context-watch]` line: finish the step and stop (after a tool call), or handle the message and report (at a prompt).
- **URGE (default 400k):** the same notice; the line says stop now, even mid-step (after a tool call), or ask before starting (at a prompt).
- Every line carries the handoff-prompt contract and the handoff file path. The hook creates the `handoffs/` directory (mode 0700); it never writes the handoff and never hard-stops the turn, which would leave the model no chance to write it.
- The handoff file sits outside the project, so a `PreToolUse` check approves a main-session `Write` to exactly this session's handoff path, and stays silent for every other write.
- Each threshold fires once per crossing. Compacting, or a drop more than 10% of WARN below a threshold, re-arms it; hovering around a threshold does not re-fire it.
- Subagent prompts and tool calls are ignored. Prompts nobody typed (`/loop` ticks, background-agent reports) do count. Headless `claude -p` runs stop like interactive ones; disable the hook for unattended automation. Handoff files older than 30 days are pruned.
- Right after a compaction the size is reported as "just compacted": the exact size is known after the next reply.

Settings come from env vars, or from `~/.config/workflow-skills/context-watch.conf` as `KEY=VALUE` lines; env wins:

| Key | Default | Meaning |
|---|---|---|
| `CONTEXT_WATCH_WARN` | `200k` | first threshold (`250000`, `250k` and `0.25m` all work) |
| `CONTEXT_WATCH_URGE` | `400k` | second threshold (raised to WARN if set lower) |
| `CONTEXT_WATCH_DISABLE` | unset | `1` turns the hook off |

On a 200k-window model, Claude Code auto-compacts at about 167k, before the 200k WARN can fire, so those sessions rely on Claude Code's own "context low" notice. The hook does not run on OpenCode: its 2.x plugin API has no stable prompt or context hooks yet.
