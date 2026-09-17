#!/usr/bin/env bash
# Stable entry for locally registered routing hooks: route-hook-shim.sh ENTRY HOST
#
# The installer copies this file to an owned location and registers it instead
# of calling delegate.sh directly. The entry it wraps can change under the hook:
# a symlink install follows whatever branch the checkout has switched to, and a
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
case "$payload" in
  *'"UserPromptSubmit"'*|*'"SessionStart"'*)
    # The router never saw this user message, so grants recorded before it must
    # not be usable: leave a timestamp every session checks.
    marker="${XDG_STATE_HOME:-$HOME/.local/state}/workflow-skills/routing/capture-failed-any"
    mkdir -p "$(dirname "$marker")" 2>/dev/null && : >"$marker" 2>/dev/null
    ;;
  *'"PreToolUse"'*)
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"opencode-subagent routing is not runnable from the installed entry point (a checkout without routing, a moved install, or a crash). Native delegation stays blocked; work locally and run opencode-delegate route doctor or re-run scripts/install.sh."}}' ;;
esac
exit 0
