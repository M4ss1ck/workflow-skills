---
name: orchestrate
description: 'Delegate a ticket, spec, or plain-language brief to OpenCode: fetch the issue, branch, one verified packet per committable unit, commit and push as it lands, then a PR. Manual command: invoke it explicitly with /orchestrate in Claude Code or OpenCode, or through the skill selector in Codex.'
argument-hint: '[issue number, #number, issue URL, owner/repo#number, or a brief]'
disable-model-invocation: true
---

Delegate to OpenCode, I'm low on usage. YAGNI throughout.
Implement the work described by the user in the spec or tickets.
If the user passes a ticket reference, fetch it from the issue tracker and state its title before starting. If the reference is ambiguous, ask.
Call the Skill tool with "tdd" where possible, at pre-agreed seams.
Orchestrator (you):
- Context budget: read the issue, then grep and read only the slices the change needs. Never open whole files to "get oriented", never read worker logs; judge the worker by git diff --stat and then the diff of changed_files.
- Packets name paths and line ranges, never pasted code. Ask for a terse report: files changed, command run, exit code, open questions.
- Go in order. One packet = one committable unit. After each unit passes your own verify: accept it, commit on the feature branch with a clear message, then move on. Push every 2-3 commits. If usage runs out, nothing done is lost.
- You own testing: after each unit, run the touched module's tests; at the end, run the full suite once, in the background. On a CI-only failure, investigate the environment difference; don't loop locally.
- Bugs: get a failing repro or test yourself before delegating the fix. No repro, no packet.
- Two failed corrections on a unit: take it over or stop and report BLOCKED. Don't let it drift.
- Decide every Task (accept/reject/take_over) before moving on; leave none in awaiting_supervisor.
Worker (put this in every packet):
- Run only the narrowest check that proves the unit: one test file or test name, plus typecheck/lint for the touched package. No full suite, no e2e, no build, no watch mode, nothing expected to take over ~60s. If the only proof is a long command, say so in the report and don't run it.
- Touch only the listed files; if more are needed, stop and report blocked.
Done = all units committed and pushed, full suite green, PR open. Notify me at the end.
