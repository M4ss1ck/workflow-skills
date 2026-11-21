# Delegation policy `off` disables OpenCode only, not native subagents

The delegation policy used to govern all delegation: under `off` the routing hook denied every native subagent call too. With per-repo config, `off` is how a repository opts out of OpenCode (a client repo whose code must not reach a third-party model, a repo where the cheap model performs badly), and denying the host's own subagents there would cripple the session for no gain. So `off` now means "never launch an OpenCode worker or researcher"; native subagents in that scope run without routing. A future reader seeing a hook that ignores native calls under `off` should know this is deliberate, not a missed case.

## Consequences

- There is no longer a policy value that disables native delegation; that belongs to the host's own permissions (for Claude Code, a deny rule on the Agent tool).
- "A review is never done by its author" still holds under `off`: the independent reviewer becomes a native subagent instead of the OpenCode researcher.
