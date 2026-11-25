---
name: orchestrate
description: 'Delegate a ticket, spec, or plain-language brief to OpenCode: fetch the issue, branch, one verified packet per committable unit, commit and push as it lands, then a PR. Manual command: invoke it explicitly with /orchestrate in Claude Code or OpenCode, or through the skill selector in Codex.'
argument-hint: '[issue number, #number, issue URL, owner/repo#number, or a brief]'
disable-model-invocation: true
---

# Orchestrate

Delegate to OpenCode: the worker implements, you orchestrate and verify. The point is to finish the work while your own context stays small. YAGNI throughout: build the smallest thing the request needs.

The request: $ARGUMENTS

## Intake

1. Empty request: ask for a ticket reference or a brief. Do not guess.
2. GitHub issue reference: a bare `123` or `#123`, an issue URL, or `owner/repo#123`. A leading reference followed by text is that issue plus the text as extra constraints. Fetch it before anything else: `gh issue view <n> --json number,title,body,url,labels` (add `-R owner/repo` when given). Fetch comments only when the body leaves a decision open. State the issue title in one line before starting.
3. Any other tracker or URL: open the page and read the ticket. If it cannot be read, ask for the text. Never invent requirements.
4. Ambiguous reference (several issue-looking tokens, a leading number `gh` cannot resolve, a repo you cannot resolve): ask which one. Never pick one. A number inside prose is part of the brief, not an issue reference.
5. Anything else is a brief. Restate the goal and the definition of done in two lines, then continue.
6. Read the repo's `AGENTS.md` and `CLAUDE.md`. Where they are stricter than this skill, they win.

## Setup

Do this before the first write.

1. Run `opencode-delegate policy`. If it reports `off`, stop and tell the user OpenCode is disabled. Do not quietly implement the ticket in this session. If the command is not on PATH, call `bash <opencode-subagent skill dir>/scripts/delegate.sh` with the same arguments; every `opencode-delegate` call below has that same fallback.
2. Resolve the base from the remote default branch, never local HEAD: `git fetch -q origin`, `git remote set-head -a origin` (ignore a failure), then `origin/main`, `origin/master`, `main`, `master`. If the tree is dirty, stop and ask. Create `<type>/<slug>` off that base.
3. Name the reference the work is judged against: the issue acceptance criteria, the real product for parity, or a frozen rubric. If none exists, write one.
4. Decompose into packets in order. One packet is one committable unit with its own acceptance command. A behavior change ships its test in the same commit; a bug fix ships the failing test that would have caught it. Name the TDD seam for every behavior-changing packet; when a `tdd` skill is available, load it. Keep the packet list in the triage message, or in a scratch file under `docs/plans/` when the repo ignores that path. Never commit it.
5. Print the triage block now, after the branch exists and before the first write: size (small, medium, large, with why), tests, delegation, branch with its resolved base (`feat/x off origin/main`), reference, TDD seams.

## Orchestrator

- **Context budget.** Read the issue, then grep and read only the slices the change needs. Never open whole files to "get oriented", never read worker logs. Judge a Task by `git diff --stat`, then the diff of its changed files only; `status` gives the parsed report.
- **Packets name paths and line ranges, never pasted code.** Ask for a terse report: files changed, commands run, exit codes, open questions. Load the `opencode-subagent` skill for the transport.
- **The worker's report is evidence, not acceptance.** Verify each unit with a command you ran yourself.
- **TDD at the seam.** For a unit that changes behavior, the failing test comes first: write it yourself at that unit's agreed seam before dispatch, or make it the first packet step and confirm it fails. A unit whose test only passes after the code is not accepted.
- **Go in order.** For each unit: `opencode-delegate start --cwd <repo> "<packet>"`, then `opencode-delegate wait <task>`. Verify with `opencode-delegate verify <task> -- <touched module's tests>` and read the exit code. On a correctable miss, `opencode-delegate retry <task> --reason "<why>" "<fix>"`. On a pass, `opencode-delegate decide <task> accept`, commit on the feature branch with a clear message, then move on.
- **Push.** The first push is `git push -u origin HEAD`; after that push every 2 or 3 commits, so running out of usage loses nothing. Before the PR, `git fetch origin && git rebase <base>` (stop if it fails), then `git push --force-with-lease --force-if-includes` on the task branch only, never on `main` or a shared branch, then `gh pr create` against the base.
- **You own testing.** The verify command above is the touched module's tests. At the end, run the full suite once, in the background. A CI-only failure is an environment difference to investigate, not a reason to loop locally.
- **Bugs.** Get a failing repro or test yourself before delegating the fix. No repro, no packet.
- **Two failed corrections on a unit.** Take it over, or stop and report BLOCKED. Do not let it drift.
- **Decide every Task** (`accept`, `reject`, `take_over`) before moving on. Leave none in `awaiting_supervisor`.

## Worker packet

Use this shape for every packet:

- `GOAL`: one sentence.
- `SCOPE`: the files and line ranges the worker may touch. Nothing else.
- `CONSTRAINTS`: the API, patterns, or behavior to preserve.
- `ACCEPTANCE`: the command the unit must pass.
- `REPORT`: files changed, commands run with exit codes, open questions, commit-ready summary.

Put these worker rules in every packet:

- Run only the narrowest check that proves the unit: one test file or test name, plus typecheck or lint for the touched package. No full suite, no e2e, no build, no watch mode, nothing expected to take over about 60 seconds. If the only proof is a long command, say so in the report and do not run it.
- A behavior change includes its test in the same patch; a bug fix includes the test that would have caught it.
- Touch only `SCOPE`. If more is needed, stop and report blocked. Do not commit, push, change branches, or install dependencies the packet did not list.
- Report what the packet asks for, including anything unresolved.

## Done

- Every unit committed on the feature branch and pushed, full suite green, PR open against the base with what changed, how it was tested, and the outcome.
- Rate your own diff from a cold read, 1 to 10. Below 10, name the gap and fix it, or say why it cannot be fixed here.
- End with one status: DONE, DONE_WITH_CONCERNS, BLOCKED, or NEEDS_CONTEXT, and the PR URL.
- Notify the user in the final message. Do not keep working past a BLOCKED.
