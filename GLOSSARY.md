# workflow-skills

Skills, hooks and plugins that shape how coding agents work across sessions and providers.

## Context watch

**Context size**:
The tokens the model re-read on its last call in a session; what every next turn pays for.
_Avoid_: Context usage, token count

**WARN**:
The first context-size threshold (200k by default), where the model finishes its step and stops.

**URGE**:
The second context-size threshold (400k by default), where the model stops at the next safe point, even mid-step.

**Handoff file**:
A Markdown file the model writes so a different session can pick up the current work cold.
_Avoid_: Handoff doc, session summary

**Handoff prompt**:
Text the user can paste unmodified into a new session to continue the current work; it points at the handoff file, or carries its full contents when the file could not be written.
_Avoid_: Continuation prompt, resume prompt

## OpenCode subagent

**Delegation policy**:
How freely the model may hand work to OpenCode: never (`off`), only when asked (`explicit`), or on its own judgment (`auto`). Under `explicit` and `auto` it also decides which native subagent calls get routed to OpenCode; under `off` native subagents are untouched.

**Global config**:
The user's delegation settings that apply wherever no repo says otherwise.

**Repo config**:
Delegation settings scoped to one repository (and every worktree of it), kept inside the repository but never committed. Overrides the global config key by key.
_Avoid_: Local config, project config

**Effective config**:
The settings actually in force for a given working directory after the repo config is layered over the global config, each value traceable to where it came from.
