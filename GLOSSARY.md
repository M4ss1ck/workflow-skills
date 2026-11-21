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
