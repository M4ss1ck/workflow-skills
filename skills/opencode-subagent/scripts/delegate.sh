#!/usr/bin/env bash
# Delegate a task to an OpenCode subagent in headless mode.
# Usage: delegate.sh [--model provider/model] [--cwd DIR] [--resume SESSION_ID] "<spec>"
set -euo pipefail

model=""
cwd=""
resume=""
spec=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)  shift; model="${1:?--model requires a value}" ;;
    --cwd)    shift; cwd="${1:?--cwd requires a path}" ;;
    --resume) shift; resume="${1:?--resume requires a session id}" ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *) spec="$1" ;;
  esac
  shift
done

[ -n "$spec" ] || { echo "ERROR: missing task spec" >&2; exit 2; }
command -v opencode >/dev/null 2>&1 || { echo "ERROR: opencode not found on PATH" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH (required to parse output)" >&2; exit 127; }

cmd=(opencode run --format json)
[ -n "$model" ] && cmd+=(--model "$model")
[ -n "$cwd" ] && cmd+=(--dir "$cwd")
[ -n "$resume" ] && cmd+=(--session "$resume")

raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT

set +e
"${cmd[@]}" "$spec" >"$raw" 2>&1
exit_code=$?
set -e

session="$(jq -rs '[.[] | .sessionID? // empty] | first // empty' "$raw" 2>/dev/null || true)"
cost="$(jq -rs '[.[] | select(.type? == "step_finish") | .part.cost? // empty] | last // empty' "$raw" 2>/dev/null || true)"
report="$(jq -rs '[.[] | select(.type? == "text") | .part.text? // empty] | last // empty' "$raw" 2>/dev/null || true)"
[ -n "$report" ] || report="$(tail -c 4000 "$raw")"

echo "SESSION: ${session:-unknown}"
echo "COST: ${cost:-unknown}"
echo "EXIT: $exit_code"
echo "--- REPORT ---"
echo "$report"
exit "$exit_code"
