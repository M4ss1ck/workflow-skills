#!/usr/bin/env bash
# Stable entry for the context-watch hook: context-watch-shim.sh ENTRY
#
# The plugin hook file and the installer both call this instead of python
# directly. The entry can disappear under the hook (a symlink install or a
# local-path plugin follows whatever branch the checkout has switched to), and
# python exits 2 for a missing script, which Claude Code reads as "block this
# user prompt". This shim passes on only hook JSON and always exits 0.
entry="${1:-}"
python="${CONTEXT_WATCH_PYTHON:-python3}"
out="$("$python" "$entry" hook 2>/dev/null)"
case "$out" in
  '{'*) printf '%s\n' "$out" ;;
esac
exit 0
