#!/usr/bin/env bash
# Stable entry for routing hooks: route-hook-shim.sh ENTRY HOST
#
# The installer copies this file to an owned location and registers it instead
# of calling delegate.sh directly; the plugin hook files call it from the plugin
# root. The entry it wraps can change under the hook: a symlink install or a
# local-path plugin follows whatever branch the checkout has switched to, and a
# branch without routing makes delegate.sh exit 2, which Claude Code treats as
# "block this user prompt". The shim turns every failure into a deny for
# delegation calls only, and into silence (exit 0) for everything else.
entry="${1:-}"
host="${2:-}"
payload="$(cat)"
out="$(printf '%s' "$payload" | bash "$entry" route hook --host "$host" 2>/dev/null)"
status=$?
if [ "$status" -eq 0 ]; then
  case "$out" in
    '') exit 0 ;;
    '{"hookSpecificOutput"'*) printf '%s\n' "$out"; exit 0 ;;
  esac
fi
# Match the event key, never the bare word: its quotes are bare only at the key,
# while a tool_input value that is just "PostToolUse" serializes the same as the
# word. PreToolUse comes first, so a payload carrying it is never let through.
# Whitespace is stripped first, so any JSON formatting of the key matches.
case "$(printf '%s' "$payload" | tr -d '[:space:]')" in
  *'"hook_event_name":"PreToolUse"'*)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"opencode-subagent routing is not runnable from the installed entry point (a checkout without routing, a moved install, or a crash). Native delegation stays blocked; work locally and run opencode-delegate route doctor or re-run scripts/install.sh. If this was a review, do not review your own work instead: tell the user no independent review ran."}}' ;;
  *'"hook_event_name":"UserPromptSubmit"'*|*'"hook_event_name":"SessionStart"'*)
    # The router never saw this user message, so grants recorded before it must
    # not be usable: leave a timestamp every session checks.
    marker="${XDG_STATE_HOME:-$HOME/.local/state}/workflow-skills/routing/capture-failed-any"
    mkdir -p "$(dirname "$marker")" 2>/dev/null && : >"$marker" 2>/dev/null
    ;;
esac
exit 0
