#!/usr/bin/env bash
# Delegate a task to a Claude Code subagent as a detached background job.
# Usage:
#   delegate.sh [--model M] [--cwd DIR] [--resume SESSION_ID] \
#               [--timeout SECS] [--permission-mode MODE] [--save-default] "<spec>"   # launch; returns immediately
#   delegate.sh --wait JOB_ID [--poll-timeout SECS]                                     # poll; exit 3 = still running
set -euo pipefail

provider="claude"
conf_key="CLAUDE_SUBAGENT_MODEL"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/workflow-skills/subagents"
conf_file="${XDG_CONFIG_HOME:-$HOME/.config}/workflow-skills/subagents.conf"
watch_filter='select(.type? == "assistant") | .message.content[]? | .text? // empty'

model=""
cwd=""
resume=""
permission_mode="acceptEdits"
spec=""
hard_timeout=1800
save_default=0
wait_job=""
poll_timeout=300
poll_interval="${DELEGATE_POLL_INTERVAL:-5}"
runner_jobdir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)           shift; model="${1:?--model requires a value}" ;;
    --cwd)             shift; cwd="${1:?--cwd requires a path}" ;;
    --resume)          shift; resume="${1:?--resume requires a session id}" ;;
    --timeout)         shift; hard_timeout="${1:?--timeout requires seconds}" ;;
    --permission-mode) shift; permission_mode="${1:?--permission-mode requires a value}" ;;
    --save-default)    save_default=1 ;;
    --wait)            shift; wait_job="${1:?--wait requires a job id}" ;;
    --poll-timeout)    shift; poll_timeout="${1:?--poll-timeout requires seconds}" ;;
    --__run)           shift; runner_jobdir="${1:?internal flag requires a job dir}" ;;
    -h|--help)         sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)               echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)                 spec="$1" ;;
  esac
  shift
done

print_watch() {
  local jobdir="$1"
  echo "WATCH:  tail -f $jobdir/raw.jsonl | jq -r '$watch_filter'"
  echo "STATUS: cat $jobdir/status"
  echo "PROGRESS: cat $jobdir/raw.jsonl"
  echo "PROVIDER_REPORT: cat $jobdir/provider-report.txt"
  echo "RESULT: cat $jobdir/result.txt"
}

build_cmd() {
  cmd=(claude -p --output-format stream-json --verbose --permission-mode "$permission_mode")
  if [ -n "$model" ]; then cmd+=(--model "$model"); fi
  if [ -n "$resume" ]; then cmd+=(--resume "$resume"); fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$hard_timeout" "$@"
  else
    "$@"
  fi
}

do_run() {
  local jobdir="$runner_jobdir"
  build_cmd

  set +e
  if [ -n "$cwd" ]; then
    (cd "$cwd" && run_with_timeout "${cmd[@]}" "$spec") >"$jobdir/raw.jsonl" 2>"$jobdir/stderr.log"
  else
    run_with_timeout "${cmd[@]}" "$spec" >"$jobdir/raw.jsonl" 2>"$jobdir/stderr.log"
  fi
  local exit_code=$?
  set -e

  local session cost report
  session="$(jq -rs '[.[] | .session_id? // empty] | first // empty' "$jobdir/raw.jsonl" 2>/dev/null || true)"
  cost="$(jq -rs '[.[] | select(.type? == "result") | .total_cost_usd? // empty] | last // empty' "$jobdir/raw.jsonl" 2>/dev/null || true)"
  report="$(jq -rs '[.[] | select(.type? == "result") | .result? // empty] | last // empty' "$jobdir/raw.jsonl" 2>/dev/null || true)"
  printf '%s\n' "$report" >"$jobdir/provider-report.txt"
  if [ -z "$report" ]; then
    report="$(tail -c 2000 "$jobdir/stderr.log"; tail -c 2000 "$jobdir/raw.jsonl")"
  fi

  {
    echo "SESSION: ${session:-unknown}"
    echo "COST: ${cost:-unknown}"
    echo "EXIT: $exit_code"
    echo "--- REPORT ---"
    echo "$report"
  } >"$jobdir/result.txt"

  local state="done"
  if [ "$exit_code" -eq 124 ]; then
    state="timeout"
  elif [ "$exit_code" -ne 0 ]; then
    state="failed"
  fi
  echo "$state $exit_code" >"$jobdir/status"
}

do_wait() {
  local jobdir="$state_root/$wait_job"
  [ -d "$jobdir" ] || { echo "ERROR: unknown job: $wait_job (looked in $state_root)" >&2; exit 2; }
  local end=$((SECONDS + poll_timeout))
  local st
  while :; do
    st="$(cat "$jobdir/status" 2>/dev/null || echo running)"
    if [ "${st%% *}" != "running" ]; then
      cat "$jobdir/result.txt"
      exit "${st##* }"
    fi
    if [ "$SECONDS" -ge "$end" ]; then
      break
    fi
    sleep "$poll_interval"
  done
  local started elapsed
  started="$(cat "$jobdir/started" 2>/dev/null || echo 0)"
  elapsed=$(( $(date +%s) - started ))
  echo "RUNNING (elapsed ${elapsed}s)"
  print_watch "$jobdir"
  exit 3
}

do_launch() {
  [ -n "$spec" ] || { echo "ERROR: missing task spec" >&2; exit 2; }
  command -v claude >/dev/null 2>&1 \
    || { echo "ERROR: claude not found on PATH — run scripts/install.sh --doctor" >&2; exit 127; }
  command -v jq >/dev/null 2>&1 \
    || { echo "ERROR: jq not found on PATH (required to parse output) — run scripts/install.sh --doctor" >&2; exit 127; }
  if [ "$save_default" -eq 1 ] && [ -z "$model" ]; then
    echo "ERROR: --save-default requires --model" >&2
    exit 2
  fi

  if [ "$save_default" -eq 1 ]; then
    mkdir -p "$(dirname "$conf_file")"
    {
      if [ -f "$conf_file" ]; then grep -v "^$conf_key=" "$conf_file" || true; fi
      echo "$conf_key=$model"
    } >"$conf_file.tmp"
    mv "$conf_file.tmp" "$conf_file"
  fi
  if [ -z "$model" ] && [ -f "$conf_file" ]; then
    model="$(sed -n "s/^$conf_key=//p" "$conf_file" | tail -1)"
  fi

  mkdir -p "$state_root"
  find "$state_root" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

  local job jobdir
  job="$provider-$(date +%Y%m%d-%H%M%S)"
  jobdir="$state_root/$job"
  while ! mkdir "$jobdir" 2>/dev/null; do
    job="$provider-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    jobdir="$state_root/$job"
  done

  date +%s >"$jobdir/started"
  echo running >"$jobdir/status"
  : >"$jobdir/raw.jsonl"
  : >"$jobdir/provider-report.txt"

  local args=(--__run "$jobdir" --timeout "$hard_timeout")
  if [ -n "$model" ]; then args+=(--model "$model"); fi
  if [ -n "$cwd" ]; then args+=(--cwd "$cwd"); fi
  if [ -n "$resume" ]; then args+=(--resume "$resume"); fi
  args+=(--permission-mode "$permission_mode")

  if command -v setsid >/dev/null 2>&1; then
    setsid bash "${BASH_SOURCE[0]}" "${args[@]}" "$spec" >/dev/null 2>"$jobdir/launcher.err" </dev/null &
  else
    nohup bash "${BASH_SOURCE[0]}" "${args[@]}" "$spec" >/dev/null 2>"$jobdir/launcher.err" </dev/null &
  fi

  echo "JOB: $job"
  print_watch "$jobdir"
}

if [ -n "$wait_job" ]; then
  do_wait
elif [ -n "$runner_jobdir" ]; then
  do_run
else
  do_launch
fi
