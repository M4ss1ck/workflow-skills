#!/usr/bin/env bash
# Delegate a task to a Claude Code subagent in headless mode.
# Usage: delegate.sh [--model M] [--cwd DIR] [--resume SESSION_ID] [--permission-mode MODE] "<spec>"
set -euo pipefail

model=""
cwd=""
resume=""
permission_mode="acceptEdits"
spec=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)  shift; model="${1:?--model requires a value}" ;;
    --cwd)    shift; cwd="${1:?--cwd requires a path}" ;;
    --resume) shift; resume="${1:?--resume requires a session id}" ;;
    --permission-mode) shift; permission_mode="${1:?--permission-mode requires a value}" ;;
    -h|--help) sed -n '2,3p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *) spec="$1" ;;
  esac
  shift
done

[ -n "$spec" ] || { echo "ERROR: missing task spec" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "ERROR: claude not found on PATH" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH (required to parse output)" >&2; exit 127; }

cmd=(claude -p --output-format json --permission-mode "$permission_mode")
[ -n "$model" ] && cmd+=(--model "$model")
[ -n "$resume" ] && cmd+=(--resume "$resume")

raw="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$raw" "$err"' EXIT

set +e
if [ -n "$cwd" ]; then
  (cd "$cwd" && "${cmd[@]}" "$spec") >"$raw" 2>"$err"
else
  "${cmd[@]}" "$spec" >"$raw" 2>"$err"
fi
exit_code=$?
set -e

session="$(jq -r '.session_id // empty' "$raw" 2>/dev/null || true)"
cost="$(jq -r '.total_cost_usd // empty' "$raw" 2>/dev/null || true)"
report="$(jq -r '.result // empty' "$raw" 2>/dev/null || true)"
[ -n "$report" ] || report="$(tail -c 2000 "$err"; tail -c 2000 "$raw")"

echo "SESSION: ${session:-unknown}"
echo "COST: ${cost:-unknown}"
echo "EXIT: $exit_code"
echo "--- REPORT ---"
echo "$report"
exit "$exit_code"
