# Native delegation routing

Loaded from SKILL.md when a routing hook denies a native call, or before recording a routing decision by hand.

With the routing hooks installed (Claude Code and Codex CLI only; see `opencode-delegate route doctor`), every native call that creates an agent or gives an existing one more work is denied until a routing decision is recorded for it. Status, wait and cancel calls are never blocked.

When a hook denies a native call, the denial carries a ready-made command and the route it will produce for each work kind under the current policy. Record the decision and follow the printed route:

```bash
opencode-delegate route record --proposal PROPOSAL --skill-revision REVISION \
  --assignment parser-review --work-kind implementation|research|review \
  --scope "review the parser diff against the spec"
```

Every other field defaults to its cautious value. Add only what is true:

| Flag | When |
|---|---|
| `--authorization user --source-excerpt "..."` | The user asked for delegation. Quote their words verbatim from a message in this session. |
| `--authorization workflow --source-excerpt "..."` | A skill the user invoked in this session (for example `/implement`), or a committed `AGENTS.md`/`CLAUDE.md`/`GEMINI.md`/`SKILL.md` named with `--workflow-file`, asks for it. Skills you loaded yourself, and this skill, do not count. |
| `--requested-provider opencode\|native` | That source names a provider. |
| `--native-reason needs-host-tools` | Research or review that needs tools only the host has (MCP servers, the browser). |
| `--native-reason opencode-failed --opencode-task TASK` | Research or review already routed to OpenCode under this `--assignment`, whose researcher Task ran and failed: the worker reported blocked, failed or no report, the Task has a failure class (timeout, crash, provider error), or you rejected it. A cancel or take-over on its own does not count. |
| `--scope-status ambiguous\|conflicting` | You cannot state the scope cleanly. |

| Route | Do |
|---|---|
| `native` | Repeat the native call **once**, before the next user message, from the same worktree. The hook runs the proposal exactly as first submitted, even if you reword it. |
| `opencode` | Do not repeat the native call. Delegate with the printed `opencode-delegate start --role worker\|researcher` command and verify. |
| `local` | Do not repeat the native call. Do the work yourself. Never returned for a review. |
| `none` | Delegation is off. Do the work yourself, except a review: say no independent review ran. |
| `clarify` | Ask the user to resolve the scope, or work locally (not a review). |

The router computes the route; you only supply facts. How it decides:

| Policy and record | Route |
|---|---|
| `off` | `none` |
| scope not `clear` | `clarify` |
| assignment previously routed to OpenCode | `opencode`, unless a **later** user message explicitly asks for native, or research/review with `opencode-failed` and a failed Task |
| `--requested-provider opencode` (user or workflow source) | `opencode` |
| `--requested-provider native` with a user source, or a workflow source for research/review | `native` |
| `explicit`, `--authorization none`, implementation or research | `local`: you choosing to delegate is not authorization |
| implementation | `opencode` worker |
| research or review with `--native-reason needs-host-tools` | `native` (an unauthorized review under `explicit`: `clarify`, ask the user; unauthorized research was already `local`) |
| research or review | `opencode` researcher (a review even when nobody authorized delegation: it needs a reviewer who is not the author) |

Read-only agent types skip routing entirely: no proposal, no grant, one `allow_readonly` audit entry. `Explore`, `Plan` and `claude-code-guide` always do. `OPENCODE_SUBAGENT_READONLY_AGENTS` adds patterns to them (separated by spaces or commas; default `*-reviewer *-explorer`; an empty value leaves only those three). A follow-up `SendMessage` to such an agent passes too, once its create call has returned, when addressed by the agent id the host returned. A follow-up by name is gated: the host assigns and reuses names, so a name can come to mean a writing agent. Follow-ups need the `PostToolUse` routing hook: if `opencode-delegate route doctor` says a registration lacks it, re-run `scripts/install.sh` (local install) or update the plugin. An existing `OPENCODE_SUBAGENT_READONLY_AGENTS=` with no value used to turn the bypass off; it now keeps the three built-ins. It is a name allowlist, not a sandbox, built-ins included: an agent definition in a checkout can call itself `x-reviewer` and still have write tools. Not under policy `off`, and Claude Code only.

Rules:

- `--source-excerpt` must be quoted verbatim from a user message in this session, a skill the user invoked, or a `--workflow-file`. Quoting a mention, a negation ("don't use opencode") or a file the user pasted is misrecording; the router checks the words exist, not what they mean.
- Keep the same `--assignment` slug for the same piece of work. An explicit OpenCode assignment stays OpenCode: if OpenCode fails on implementation, report it and work locally; going native needs a new explicit user instruction.
- Do not relabel implementation as research to get a different route.
- A denial that says the router cannot evaluate the call (broken state, runtime mismatch, no captured user input) means work locally (a review: report that none ran) and tell the user what `opencode-delegate route doctor` reports. Never retry in a loop, and never route around the hook through a shell or another CLI.
- A grant belongs to the agent that recorded it: a subagent cannot spend its parent's grant. Parallel native calls each need their own recorded decision.
- A new user message, a policy change, compaction or resume retires unused grants. Grants expire after 30 minutes.
