#!/usr/bin/env bash
# Delegate a task to an OpenCode subagent as a detached background job.
# Usage:
#   delegate.sh [--model provider/model] [--cwd DIR] [--resume SESSION_ID] \
#               [--timeout SECS] [--save-default] "<spec>"   # launch; returns immediately
#   delegate.sh --wait JOB_ID [--poll-timeout SECS]          # exit 3 = running; 4 = resume
set -euo pipefail

provider="opencode"
conf_key="OPENCODE_SUBAGENT_MODEL"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/workflow-skills/subagents"
conf_file="${XDG_CONFIG_HOME:-$HOME/.config}/workflow-skills/subagents.conf"
watch_filter='.part.text? // empty'

model=""
cwd=""
resume=""
spec=""
hard_timeout=1800
save_default=0
wait_job=""
poll_timeout=300
poll_interval="${DELEGATE_POLL_INTERVAL:-5}"
runner_jobdir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)        shift; model="${1:?--model requires a value}" ;;
    --cwd)          shift; cwd="${1:?--cwd requires a path}" ;;
    --resume)       shift; resume="${1:?--resume requires a session id}" ;;
    --timeout)      shift; hard_timeout="${1:?--timeout requires seconds}" ;;
    --save-default) save_default=1 ;;
    --wait)         shift; wait_job="${1:?--wait requires a job id}" ;;
    --poll-timeout) shift; poll_timeout="${1:?--poll-timeout requires seconds}" ;;
    --__run)        shift; runner_jobdir="${1:?internal flag requires a job dir}" ;;
    -h|--help)      sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)            echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    *)              spec="$1" ;;
  esac
  shift
done

print_watch() {
  local jobdir="$1"
  echo "WATCH:  tail -f $jobdir/raw.jsonl | jq -r '$watch_filter'"
  echo "STATUS: cat $jobdir/status"
  echo "PROGRESS: cat $jobdir/provider-progress.json"
  echo "PROVIDER_REPORT: cat $jobdir/provider-report.txt"
  echo "RESULT: cat $jobdir/result.txt"
}

provider_db_available() {
  local db_path
  db_path="$(opencode db path 2>/dev/null | tail -1)"
  [ -n "$db_path" ] && [ -f "$db_path" ]
}

sql_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

provider_final_id() {
  local session_id="$1"
  local session_sql
  session_sql="$(sql_quote "$session_id")"
  opencode db "SELECT id FROM message WHERE session_id=$session_sql AND json_extract(data, '$.role') = 'assistant' AND json_extract(data, '$.finish') = 'stop' ORDER BY time_created DESC LIMIT 1" --format json 2>/dev/null \
    | jq -r '.[0].id // empty' 2>/dev/null
}

provider_report() {
  local session_id="$1"
  local message_id="$2"
  local session_sql message_sql
  session_sql="$(sql_quote "$session_id")"
  message_sql="$(sql_quote "$message_id")"
  opencode db "SELECT json_extract(data, '$.text') AS text FROM part WHERE session_id=$session_sql AND message_id=$message_sql AND json_extract(data, '$.type') = 'text' ORDER BY time_created DESC LIMIT 1" --format json 2>/dev/null \
    | jq -r '.[0].text // empty' 2>/dev/null
}

provider_cost() {
  local session_id="$1"
  local session_sql
  session_sql="$(sql_quote "$session_id")"
  opencode db "SELECT COALESCE(SUM(CAST(json_extract(data, '$.cost') AS REAL)), 0) AS cost FROM message WHERE session_id=$session_sql AND json_extract(data, '$.role') = 'assistant'" --format json 2>/dev/null \
    | jq -r '.[0].cost // empty' 2>/dev/null
}

provider_latest_assistant_id() {
  local session_id="$1"
  local session_sql
  session_sql="$(sql_quote "$session_id")"
  opencode db "SELECT id FROM message WHERE session_id=$session_sql AND json_extract(data, '$.role') = 'assistant' ORDER BY time_created DESC LIMIT 1" --format json 2>/dev/null \
    | jq -r '.[0].id // empty' 2>/dev/null
}

provider_assistant_finish() {
  local session_id="$1"
  local message_id="$2"
  local session_sql message_sql
  session_sql="$(sql_quote "$session_id")"
  message_sql="$(sql_quote "$message_id")"
  opencode db "SELECT json_extract(data, '$.finish') AS finish FROM message WHERE session_id=$session_sql AND id=$message_sql LIMIT 1" --format json 2>/dev/null \
    | jq -r '.[0].finish // empty' 2>/dev/null
}

snapshot_provider_progress() {
  local jobdir="$1"
  local session_id="$2"
  local session_sql
  local tmp="$jobdir/provider-progress.json.tmp"
  session_sql="$(sql_quote "$session_id")"
  if opencode db "SELECT time_created, message_id, json_extract(data, '$.type') AS type, json_extract(data, '$.tool') AS tool, json_extract(data, '$.state.status') AS status, substr(json_extract(data, '$.text'), 1, 2000) AS text FROM part WHERE session_id=$session_sql ORDER BY time_created DESC LIMIT 100" --format json >"$tmp" 2>/dev/null; then
    mv "$tmp" "$jobdir/provider-progress.json"
  else
    rm -f "$tmp"
  fi
}

stream_session() {
  local raw_jsonl="$1"
  jq -rs '[.[] | .sessionID? // empty] | first // empty' "$raw_jsonl" 2>/dev/null || true
}

build_cmd() {
  cmd=(opencode run --format json)
  if [ -n "$model" ]; then cmd+=(--model "$model"); fi
  if [ -n "$cwd" ]; then cmd+=(--dir "$cwd"); fi
  if [ -n "$resume" ]; then cmd+=(--session "$resume"); fi
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
  local session cost report final_id db_report db_cost assistant_id assistant_finish
  local baseline_final_id="" baseline_assistant_id=""
  local baseline_final_ready=0 baseline_assistant_ready=0
  local runner_pid provider_complete=0 exit_code db_available=0
  build_cmd
  if provider_db_available; then db_available=1; fi
  if [ "$db_available" -eq 1 ] && [ -n "$resume" ]; then
    if baseline_final_id="$(provider_final_id "$resume")"; then baseline_final_ready=1; fi
    if baseline_assistant_id="$(provider_latest_assistant_id "$resume")"; then baseline_assistant_ready=1; fi
  fi

  set +e
  if [ "$db_available" -eq 1 ] && command -v setsid >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      setsid timeout "$hard_timeout" "${cmd[@]}" "$spec" >"$jobdir/raw.jsonl" 2>"$jobdir/stderr.log" &
    else
      setsid "${cmd[@]}" "$spec" >"$jobdir/raw.jsonl" 2>"$jobdir/stderr.log" &
    fi
    runner_pid=$!
    session="$resume"

    while kill -0 "$runner_pid" 2>/dev/null; do
      if [ -z "$session" ]; then session="$(stream_session "$jobdir/raw.jsonl")"; fi
      if [ -n "$session" ]; then
        snapshot_provider_progress "$jobdir" "$session"
        if final_id="$(provider_final_id "$session")" \
          && [ -n "$final_id" ] \
          && { [ -z "$resume" ] || { [ "$baseline_final_ready" -eq 1 ] && [ "$final_id" != "$baseline_final_id" ]; }; } \
          && db_report="$(provider_report "$session" "$final_id")"; then
          printf '%s\n' "$db_report" >"$jobdir/provider-report.txt"
          provider_complete=1
          kill -TERM -- "-$runner_pid" 2>/dev/null || true
          wait "$runner_pid" 2>/dev/null
          break
        fi
      fi
      sleep "$poll_interval"
    done

    if [ "$provider_complete" -eq 1 ]; then
      exit_code=0
    else
      wait "$runner_pid"
      exit_code=$?
    fi
  else
    run_with_timeout "${cmd[@]}" "$spec" >"$jobdir/raw.jsonl" 2>"$jobdir/stderr.log"
    exit_code=$?
  fi
  set -e

  session="${resume:-$(stream_session "$jobdir/raw.jsonl")}"
  cost="$(jq -rs '[.[] | select(.type? == "step_finish") | .part.cost? // empty] | last // empty' "$jobdir/raw.jsonl" 2>/dev/null || true)"
  report="$(jq -rs '[.[] | select(.type? == "text") | .part.text? // empty] | last // empty' "$jobdir/raw.jsonl" 2>/dev/null || true)"

  if [ "$db_available" -eq 1 ] && [ -n "$session" ]; then
    snapshot_provider_progress "$jobdir" "$session"
    if final_id="$(provider_final_id "$session")"; then
      if [ -n "$final_id" ] \
        && { [ -z "$resume" ] || { [ "$baseline_final_ready" -eq 1 ] && [ "$final_id" != "$baseline_final_id" ]; }; }; then
        if db_report="$(provider_report "$session" "$final_id")" && [ -n "$db_report" ]; then report="$db_report"; fi
        if [ -z "$cost" ] && db_cost="$(provider_cost "$session")" && [ -n "$db_cost" ]; then cost="$db_cost"; fi
      elif [ "$exit_code" -eq 0 ] \
        && assistant_id="$(provider_latest_assistant_id "$session")" \
        && [ -n "$assistant_id" ] \
        && { [ -z "$resume" ] || { [ "$baseline_assistant_ready" -eq 1 ] && [ "$assistant_id" != "$baseline_assistant_id" ]; }; } \
        && assistant_finish="$(provider_assistant_finish "$session" "$assistant_id")" \
        && [ -z "$assistant_finish" ]; then
        exit_code=4
        report="${report}"$'\n\n'"ERROR: OpenCode exited before producing a provider-final response. Resume this session."
      fi
    fi
  fi

  if [ -z "$report" ]; then
    report="$(tail -c 2000 "$jobdir/stderr.log"; tail -c 2000 "$jobdir/raw.jsonl")"
  fi
  printf '%s\n' "$report" >"$jobdir/provider-report.txt"

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
  elif [ "$exit_code" -eq 4 ]; then
    state="incomplete"
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
  command -v opencode >/dev/null 2>&1 \
    || { echo "ERROR: opencode not found on PATH — run scripts/install.sh --doctor" >&2; exit 127; }
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
  echo '[]' >"$jobdir/provider-progress.json"
  : >"$jobdir/provider-report.txt"

  local args=(--__run "$jobdir" --timeout "$hard_timeout")
  if [ -n "$model" ]; then args+=(--model "$model"); fi
  if [ -n "$cwd" ]; then args+=(--cwd "$cwd"); fi
  if [ -n "$resume" ]; then args+=(--resume "$resume"); fi

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
