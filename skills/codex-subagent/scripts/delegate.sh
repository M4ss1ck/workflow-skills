#!/usr/bin/env bash
# Delegate a task to a Codex subagent in headless mode.
# Usage: delegate.sh [--model M] [--cwd DIR] [--resume SESSION_ID] "<spec>"
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
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not found on PATH" >&2; exit 127; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found on PATH (required to parse output)" >&2; exit 127; }

if [ -n "$resume" ]; then
  cmd=(codex exec --json resume "$resume")
else
  cmd=(codex exec --json -s workspace-write --skip-git-repo-check)
  [ -n "$model" ] && cmd+=(-m "$model")
  [ -n "$cwd" ] && cmd+=(-C "$cwd")
fi

raw="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$raw" "$err"' EXIT

set +e
"${cmd[@]}" "$spec" >"$raw" 2>"$err"
exit_code=$?
set -e

session="$(jq -rs '[.[] | select(.type? == "thread.started") | .thread_id? // empty] | first // empty' "$raw" 2>/dev/null || true)"
usage="$(jq -rs '[.[] | select(.type? == "turn.completed") | .usage? // empty] | last // empty | if . == "" then "" else "\(.input_tokens) in / \(.output_tokens) out tokens" end' "$raw" 2>/dev/null || true)"
report="$(jq -rs '[.[] | select(.type? == "item.completed") | .item? // empty | select(.type? == "agent_message") | .text? // empty] | last // empty' "$raw" 2>/dev/null || true)"
[ -n "$report" ] || report="$(tail -c 2000 "$err"; tail -c 2000 "$raw")"

echo "SESSION: ${session:-unknown}"
echo "COST: ${usage:-unknown}"
echo "EXIT: $exit_code"
echo "--- REPORT ---"
echo "$report"
exit "$exit_code"
