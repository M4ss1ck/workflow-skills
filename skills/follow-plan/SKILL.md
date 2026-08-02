---
name: follow-plan
description: 'Enforce exact execution of a provided ordered plan, checklist, runbook, or implementation document without autonomous deviation. Use when the user asks to execute an already-decided plan and fidelity matters. Do not use merely because a broad specification or goal exists.'
---

# Follow Plan

<EXTREMELY-IMPORTANT>
When a plan is provided for execution, its explicit decisions own the execution. You are its executor, not its designer. Do not replace a plan choice with a workflow default or preferred practice. Use established defaults only where the plan is silent and the choice cannot materially change meaning, scope, sequence, implementation, or outcome; otherwise STOP and ask.
</EXTREMELY-IMPORTANT>

## Iron Rule

```
PLAN DECISIONS OVERRIDE EXECUTION DEFAULTS.
```

This skill governs execution only within higher-priority instructions, safety rules, tool constraints, and the user’s current authorization. If the plan conflicts with any higher-priority requirement, STOP and report the conflict. Do not treat the plan as permission to violate external constraints.

Follow the plan's letter when it is executable and internally consistent. Never improve, reinterpret, reorder, expand, omit, substitute, or silently repair it. Within the same instruction priority, explicit plan directions take precedence over general repository conventions, auxiliary workflows, skill defaults, and best practices. Ignore a conflicting default rather than stopping; stop only when the conflict is with a higher-priority requirement or the plan itself is ambiguous or inconsistent.

When the plan is silent on a subject:

- Use a single established project convention or necessary mechanical default if it adds no scope and has no materially different outcome.
- Suggest a relevant best practice only if the plan has not already chosen differently. Present it as optional and do not delay the plan for it.
- Stop and ask if multiple materially different choices remain or the choice could affect scope, behavior, dependencies, public interfaces, data, sequence, implementation strategy, or outcome.

Never enforce a preferred commit strategy, testing cadence, refactor, cleanup, or other workflow convention against an explicit plan direction. For example, if the plan requires a commit after each task, do not wait until the whole feature is complete because another workflow recommends feature-level commits. If the plan says nothing about commits, do not add commits as execution steps; at most suggest a commit strategy separately.

User clarifications amend the plan persistently for all remaining steps. If a later ambiguity is not resolved by an amendment, stop again.

## Before Execution

1. Read the entire plan and all referenced instructions.
2. Compare explicit plan assumptions with the relevant current state using read-only inspection limited to files, commands, resources, and prerequisites referenced by the plan or required to determine whether the next step is executable.
3. Identify missing material details, internal contradictions, unavailable requirements, and conflicts with higher-priority constraints.
4. Resolve non-material gaps only through a single established convention or necessary mechanical default. Stop and ask about every unresolved material decision before changing anything.
5. Execute resolved steps in order and report progress against their exact wording.

## Proceed Gate

Proceed only when every statement is true:

1. The plan explicitly authorizes the result.
2. The action is necessary to produce the explicitly authorized result, or is an explicitly requested verification step.
3. The action adds no scope, behavior, dependency, or material design choice.
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
| The plan specifies commit timing that differs from a workflow convention | Follow the plan's timing. Do not enforce the conflicting convention; note it only if the user needs to know. |
| The plan is silent about commits | Do not commit; optionally suggest a strategy after executing the plan. |
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
- “My usual best practice is better than the plan's choice.”
- “I can choose a sensible default even though the plan already decided, or the choice is material.”
- “The plan is outdated, so I will adapt it.”
- “This cleanup is closely related.”
- “Stopping would be inefficient.”

These thoughts mean you are inventing paralysis:

- “I should ask even though the plan already chose.”
- “Choosing the sole documented command is a design decision.”
- “A conflicting workflow default means I should stop even though the plan is explicit.”
- “Every filesystem operation needs separate confirmation.”

Do not improvise. Do not manufacture uncertainty. Execute what the plan has decided, and use defaults only inside the narrow gaps defined above.
