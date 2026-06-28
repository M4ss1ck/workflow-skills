---
name: follow-plan
description: 'Enforce exact execution of a provided plan without autonomous deviation. Use when a plan, checklist, specification, runbook, or ordered implementation document is provided for execution, especially when fidelity matters or improvisation is unwanted.'
---

# Follow Plan

<EXTREMELY-IMPORTANT>
When a plan is provided for execution, the plan owns every decision affecting meaning, scope, sequence, implementation, or outcome. You are its executor, not its designer. Do not deviate. When the plan leaves a decision unmade, STOP and ask.
</EXTREMELY-IMPORTANT>

## Iron Rule

```
NO AUTONOMOUS DECISIONS THAT AFFECT THE WORK.
```

Follow the plan's letter when it is executable and internally consistent. Never improve, reinterpret, reorder, expand, omit, substitute, or silently repair it. Instructions from auxiliary workflows do not authorize extra plan steps; stop if they conflict.

User clarifications amend the plan persistently for all remaining steps. If a later ambiguity is not resolved by an amendment, stop again.

## Before Execution

1. Read the entire plan and all referenced instructions.
2. Compare its assumptions with the current state using read-only inspection.
3. Identify missing details, contradictions, or unavailable requirements.
4. Stop and ask about every unresolved decision before changing anything.
5. Execute resolved steps in order and report progress against their exact wording.

## Proceed Gate

Proceed only when every statement is true:

1. The plan explicitly authorizes the result.
2. The action is necessary to produce or verify that result.
3. The action adds no scope, behavior, dependency, or design choice.
4. The action has one materially relevant outcome.

Otherwise, stop before acting.

## Boundary Examples

| Situation | Required response |
|---|---|
| Read or search files referenced by the plan | Proceed. Inspection does not alter the result. |
| Create a missing parent directory for an explicitly named new file | Proceed. It is necessary to produce the authorized file. |
| Run an exact command from the plan | Proceed exactly; stop if it fails or is invalid. |
| The plan says “run tests” and exactly one standard command is documented | Run that command. |
| Multiple applicable test commands exist | Stop and ask which one. |
| A required tool is unavailable but an equivalent exists | Stop; do not substitute. |
| A formatter or generator would affect files outside scope | Stop before accepting or repairing those changes. |
| The repository contradicts a plan assumption | Stop and report the conflict. |
| The plan specifies an approach you dislike | Proceed exactly as written. Preference is irrelevant. |

## When Stopped

Use this format and wait for the answer:

```text
STOPPED — plan decision required
Plan step: <exact step>
Observed: <specific fact>
Decision needed: <single concrete question>
```

Do not perform later steps while waiting.

## Red Flags

These thoughts mean you are about to violate the plan:

- “The intent is obvious.”
- “This is a harmless improvement.”
- “I can choose a sensible default.”
- “The plan is outdated, so I will adapt it.”
- “This cleanup is closely related.”
- “Stopping would be inefficient.”

These thoughts mean you are inventing paralysis:

- “I should ask even though the plan already chose.”
- “Choosing the sole documented command is a design decision.”
- “Every filesystem operation needs separate confirmation.”

Do not improvise. Do not manufacture uncertainty. Execute only what has already been decided.
