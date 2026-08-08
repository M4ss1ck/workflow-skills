#!/usr/bin/env bash
# Delegate a bounded task to the constrained OpenCode worker agent as a detached job.
#
# Operations:
#   delegate.sh start  [opts] "<task>"          launch detached; returns immediately
#   delegate.sh run    [opts] "<task>"          launch and block until the job ends
#   delegate.sh resume SESSION_ID "<fix>"       continue an existing worker session
#   delegate.sh status JOB_ID                   report state without blocking
#   delegate.sh wait   JOB_ID [--poll-timeout SECS]
#   delegate.sh cancel JOB_ID                   kill a running job
#   delegate.sh policy [off|explicit|auto]      read or set the delegation policy
#
# Options:
#   --model provider/model   worker model (overrides the configured one)
#   --cwd DIR                working tree for the worker
#   --resume SESSION_ID      continue a session (start/run)
#   --timeout SECS           hard kill after SECS (default 1800)
#   --poll-timeout SECS      how long `wait` blocks before reporting RUNNING
#   --save-default           persist --model as the configured worker model
#   --json                   machine-readable output
#
# Exit codes: 0 finished  2 usage/config  3 still running  4 incomplete turn (resume it)
#             124 timeout  127 missing CLI  130 cancelled
#
# Legacy forms still accepted: `delegate.sh [opts] "<task>"` and `delegate.sh --wait JOB_ID`.
set -euo pipefail

provider="opencode"
agent_name="workflow-worker"
model_key="OPENCODE_SUBAGENT_MODEL"
policy_key="OPENCODE_SUBAGENT_DELEGATION_POLICY"
default_policy="explicit"
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/workflow-skills/subagents"
conf_file="${XDG_CONFIG_HOME:-$HOME/.config}/workflow-skills/subagents.conf"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
agent_src="$skill_dir/agents/$agent_name.md"
agent_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/agent"
agent_dest="$agent_dir/$agent_name.md"
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
json_out=0
job=""
jobdir=""
positionals=()

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $1" >&2; exit "${2:-2}"; }

op=""
case "${1:-}" in
  start|run|resume|status|wait|cancel|policy) op="$1"; shift ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)        shift; model="${1:?--model requires a value}" ;;
    --cwd)          shift; cwd="${1:?--cwd requires a path}" ;;
    --resume)       shift; resume="${1:?--resume requires a session id}" ;;
    --timeout)      shift; hard_timeout="${1:?--timeout requires seconds}" ;;
    --save-default) save_default=1 ;;
    --wait)         shift; wait_job="${1:?--wait requires a job id}" ;;
    --poll-timeout) shift; poll_timeout="${1:?--poll-timeout requires seconds}" ;;
    --json)         json_out=1 ;;
    --__run)        shift; runner_jobdir="${1:?internal flag requires a job dir}" ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; while [ "$#" -gt 0 ]; do positionals+=("$1"); shift; done; break ;;
    --*)            die "unknown option: $1" ;;
    *)              positionals+=("$1") ;;
  esac
  shift
done

# ---------------------------------------------------------------- configuration

conf_get() {
  [ -f "$conf_file" ] || return 0
  sed -n "s/^$1=//p" "$conf_file" | tail -1
}

conf_set() {
  mkdir -p "$(dirname "$conf_file")"
  {
    if [ -f "$conf_file" ]; then grep -v "^$1=" "$conf_file" || true; fi
    echo "$1=$2"
  } >"$conf_file.tmp"
  mv "$conf_file.tmp" "$conf_file"
}

resolve_policy() {
  local value
  value="$(conf_get "$policy_key")"
  value="${value:-$default_policy}"
  case "$value" in
    off|explicit|auto) echo "$value" ;;
    *) die "invalid $policy_key in $conf_file: $value (want off|explicit|auto)" ;;
  esac
}

# --model wins, then the configured worker model. Never inherit OpenCode's own
# default: this skill exists to run a specific cheap model, not whatever is global.
resolve_model() {
  if [ -z "$model" ]; then model="$(conf_get "$model_key")"; fi
  [ -n "$model" ] || die "no worker model: pass --model provider/model, or save one with --model provider/model --save-default (conf: $conf_file)"
}

# --agent falls back to OpenCode's default agent with only a warning when the
# name is unknown, so the definition has to be on disk before we launch.
ensure_agent() {
  [ -f "$agent_src" ] || die "worker agent definition missing: $agent_src"
  if [ ! -f "$agent_dest" ] || ! cmp -s "$agent_src" "$agent_dest"; then
    mkdir -p "$agent_dir"
    cp "$agent_src" "$agent_dest.tmp"
    mv "$agent_dest.tmp" "$agent_dest"
  fi
}

# ------------------------------------------------------------------- job output

print_watch() {
  local dir="$1"
  echo "WATCH:  tail -f $dir/raw.jsonl | jq -r '$watch_filter'"
  echo "STATUS: cat $dir/status"
  echo "PROGRESS: cat $dir/provider-progress.json"
  echo "PROVIDER_REPORT: cat $dir/provider-report.txt"
  echo "RESULT: cat $dir/result.txt"
}

job_field() { cat "$1/$2" 2>/dev/null || true; }

job_elapsed() {
  local started
  started="$(job_field "$1" started)"
  echo $(( $(date +%s) - ${started:-0} ))
}

json_state_for() {
  case "$1" in
    done) echo completed ;;
    *)    echo "$1" ;;
  esac
}

json_job() {
  local dir="$1" id="$2" state="$3" code="$4"
  local report_file="$dir/provider-report.txt" changed_file="$dir/changed-files.txt"
  [ -f "$report_file" ] || report_file=/dev/null
  [ -f "$changed_file" ] || changed_file=/dev/null
  jq -n \
    --arg job_id "$id" \
    --arg state "$(json_state_for "$state")" \
    --arg session "$(job_field "$dir" session)" \
    --arg model "$(job_field "$dir" model)" \
    --arg agent "$agent_name" \
    --arg cwd "$(job_field "$dir" cwd)" \
    --arg cost "$(job_field "$dir" cost)" \
    --arg code "$code" \
    --argjson elapsed "$(job_elapsed "$dir")" \
    --arg state_dir "$dir" \
    --rawfile report "$report_file" \
    --rawfile changed "$changed_file" \
    '{
      job_id: $job_id,
      state: $state,
      session_id: (if $session == "" then null else $session end),
      model: (if $model == "" then null else $model end),
      agent: $agent,
      cwd: (if $cwd == "" then null else $cwd end),
      exit_code: (if $code == "" then null else ($code | tonumber) end),
      cost_usd: (($cost | tonumber?) // null),
      elapsed_seconds: $elapsed,
      state_dir: $state_dir,
      report: (if $state == "running" then null else $report end),
      changed_files: ($changed | split("\n") | map(select(length > 0)))
    }'
}

# ------------------------------------------------------- provider (OpenCode) IO
# Everything below reads OpenCode's local database. It is an implementation
# detail, not a stable interface: every query is best-effort and the caller
# falls back to the CLI event stream when a query fails or the schema drifts.

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
  local dir="$1"
  local session_id="$2"
  local session_sql
  local tmp="$dir/provider-progress.json.tmp"
  session_sql="$(sql_quote "$session_id")"
  if opencode db "SELECT time_created, message_id, json_extract(data, '$.type') AS type, json_extract(data, '$.tool') AS tool, json_extract(data, '$.state.status') AS status, substr(json_extract(data, '$.text'), 1, 2000) AS text FROM part WHERE session_id=$session_sql ORDER BY time_created DESC LIMIT 100" --format json >"$tmp" 2>/dev/null; then
    mv "$tmp" "$dir/provider-progress.json"
  else
    rm -f "$tmp"
  fi
}

stream_session() {
  local raw_jsonl="$1"
  jq -rs '[.[] | .sessionID? // empty] | first // empty' "$raw_jsonl" 2>/dev/null || true
}

# ------------------------------------------------------------------ changed files
# Best-effort: the worktree diff between launch and finish. A file that was
# already dirty in the same way before the run is invisible here, so this is a
# hint for the supervisor's review, not an audit log.

git_porcelain() {
  git -C "$1" status --porcelain --untracked-files=all 2>/dev/null || true
}

record_changed_files() {
  local dir="$1" work="$2"
  : >"$dir/changed-files.txt"
  [ -f "$dir/git-before.txt" ] || return 0
  git_porcelain "$work" >"$dir/git-after.txt"
  comm -13 <(sort "$dir/git-before.txt") <(sort "$dir/git-after.txt") 2>/dev/null \
    | cut -c4- | sed 's/.* -> //' | sort -u >"$dir/changed-files.txt" || : >"$dir/changed-files.txt"
}

# --------------------------------------------------------------------- runner

build_cmd() {
  cmd=(opencode run --format json --agent "$agent_name" --model "$model")
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
  local dir="$runner_jobdir"
  local work="${cwd:-$PWD}"
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
      setsid timeout "$hard_timeout" "${cmd[@]}" "$spec" >"$dir/raw.jsonl" 2>"$dir/stderr.log" &
    else
      setsid "${cmd[@]}" "$spec" >"$dir/raw.jsonl" 2>"$dir/stderr.log" &
    fi
    runner_pid=$!
    session="$resume"
    if [ -n "$session" ]; then printf '%s\n' "$session" >"$dir/session"; fi

    while kill -0 "$runner_pid" 2>/dev/null; do
      if [ -z "$session" ]; then
        session="$(stream_session "$dir/raw.jsonl")"
        if [ -n "$session" ]; then printf '%s\n' "$session" >"$dir/session"; fi
      fi
      if [ -n "$session" ]; then
        snapshot_provider_progress "$dir" "$session"
        if final_id="$(provider_final_id "$session")" \
          && [ -n "$final_id" ] \
          && { [ -z "$resume" ] || { [ "$baseline_final_ready" -eq 1 ] && [ "$final_id" != "$baseline_final_id" ]; }; } \
          && db_report="$(provider_report "$session" "$final_id")"; then
          printf '%s\n' "$db_report" >"$dir/provider-report.txt"
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
    run_with_timeout "${cmd[@]}" "$spec" >"$dir/raw.jsonl" 2>"$dir/stderr.log"
    exit_code=$?
  fi
  set -e

  session="${resume:-$(stream_session "$dir/raw.jsonl")}"
  cost="$(jq -rs '[.[] | select(.type? == "step_finish") | .part.cost? // empty] | last // empty' "$dir/raw.jsonl" 2>/dev/null || true)"
  report="$(jq -rs '[.[] | select(.type? == "text") | .part.text? // empty] | last // empty' "$dir/raw.jsonl" 2>/dev/null || true)"

  if [ "$db_available" -eq 1 ] && [ -n "$session" ]; then
    snapshot_provider_progress "$dir" "$session"
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
    report="$(tail -c 2000 "$dir/stderr.log"; tail -c 2000 "$dir/raw.jsonl")"
  fi
  printf '%s\n' "$report" >"$dir/provider-report.txt"
  printf '%s\n' "${session:-}" >"$dir/session"
  printf '%s\n' "${cost:-}" >"$dir/cost"
  record_changed_files "$dir" "$work"

  {
    echo "SESSION: ${session:-unknown}"
    echo "COST: ${cost:-unknown}"
    echo "EXIT: $exit_code"
    echo "--- REPORT ---"
    echo "$report"
  } >"$dir/result.txt"

  local state="done"
  if [ "$exit_code" -eq 124 ]; then
    state="timeout"
  elif [ "$exit_code" -eq 4 ]; then
    state="incomplete"
  elif [ "$exit_code" -ne 0 ]; then
    state="failed"
  fi
  echo "$state $exit_code" >"$dir/status"
}

# ------------------------------------------------------------------ operations

require_job() {
  [ -n "$wait_job" ] || die "missing job id"
  jobdir="$state_root/$wait_job"
  [ -d "$jobdir" ] || die "unknown job: $wait_job (looked in $state_root)"
}

emit_terminal() {
  local st="$1"
  if [ "$json_out" -eq 1 ]; then
    json_job "$jobdir" "$wait_job" "${st%% *}" "${st##* }"
  else
    cat "$jobdir/result.txt"
  fi
  exit "${st##* }"
}

emit_running() {
  if [ "$json_out" -eq 1 ]; then
    json_job "$jobdir" "$wait_job" running ""
  else
    echo "RUNNING (elapsed $(job_elapsed "$jobdir")s)"
    print_watch "$jobdir"
  fi
  exit 3
}

do_status() {
  require_job
  local st
  st="$(job_field "$jobdir" status)"
  st="${st:-running}"
  if [ "${st%% *}" != "running" ]; then emit_terminal "$st"; fi
  emit_running
}

do_wait() {
  require_job
  local end=$((SECONDS + poll_timeout))
  local st
  while :; do
    st="$(job_field "$jobdir" status)"
    st="${st:-running}"
    if [ "${st%% *}" != "running" ]; then emit_terminal "$st"; fi
    if [ "$SECONDS" -ge "$end" ]; then break; fi
    sleep "$poll_interval"
  done
  emit_running
}

do_cancel() {
  require_job
  local st pid
  st="$(job_field "$jobdir" status)"
  st="${st:-running}"
  if [ "${st%% *}" != "running" ]; then emit_terminal "$st"; fi
  pid="$(job_field "$jobdir" pid)"
  if [ -n "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  fi
  sleep 1
  echo "cancelled 130" >"$jobdir/status"
  {
    echo "SESSION: $(job_field "$jobdir" session)"
    echo "COST: $(job_field "$jobdir" cost)"
    echo "EXIT: 130"
    echo "--- REPORT ---"
    echo "Cancelled by the supervisor before the worker reported."
  } >"$jobdir/result.txt"
  emit_terminal "cancelled 130"
}

do_policy() {
  local requested="${positionals[0]:-}"
  if [ -n "$requested" ]; then
    case "$requested" in
      off|explicit|auto) conf_set "$policy_key" "$requested" ;;
      *) die "invalid policy: $requested (want off|explicit|auto)" ;;
    esac
  fi
  local current worker
  current="$(resolve_policy)"
  worker="$(conf_get "$model_key")"
  if [ "$json_out" -eq 1 ]; then
    jq -n --arg policy "$current" --arg model "$worker" --arg conf "$conf_file" --arg agent "$agent_name" \
      '{delegation_policy: $policy, worker_model: (if $model == "" then null else $model end), agent: $agent, conf_file: $conf}'
  else
    echo "DELEGATION_POLICY: $current"
    echo "WORKER_MODEL: ${worker:-none}"
    echo "CONF: $conf_file"
  fi
}

do_launch() {
  [ -n "$spec" ] || die "missing task spec"
  command -v opencode >/dev/null 2>&1 \
    || die "opencode not found on PATH — run scripts/install.sh --doctor" 127
  command -v jq >/dev/null 2>&1 \
    || die "jq not found on PATH (required to parse output) — run scripts/install.sh --doctor" 127
  if [ "$save_default" -eq 1 ]; then
    [ -n "$model" ] || die "--save-default requires --model"
    conf_set "$model_key" "$model"
  fi

  local policy
  policy="$(resolve_policy)"
  [ "$policy" != "off" ] \
    || die "delegation is disabled ($policy_key=off in $conf_file); enable it with: delegate.sh policy explicit"

  resolve_model
  ensure_agent

  mkdir -p "$state_root"
  find "$state_root" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

  job="$provider-$(date +%Y%m%d-%H%M%S)"
  jobdir="$state_root/$job"
  while ! mkdir "$jobdir" 2>/dev/null; do
    job="$provider-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    jobdir="$state_root/$job"
  done

  date +%s >"$jobdir/started"
  echo running >"$jobdir/status"
  printf '%s\n' "$model" >"$jobdir/model"
  printf '%s\n' "${cwd:-$PWD}" >"$jobdir/cwd"
  printf '%s\n' "$resume" >"$jobdir/session"
  : >"$jobdir/raw.jsonl"
  : >"$jobdir/cost"
  : >"$jobdir/changed-files.txt"
  echo '[]' >"$jobdir/provider-progress.json"
  : >"$jobdir/provider-report.txt"
  git_porcelain "${cwd:-$PWD}" >"$jobdir/git-before.txt"

  local args=(--__run "$jobdir" --timeout "$hard_timeout" --model "$model")
  if [ -n "$cwd" ]; then args+=(--cwd "$cwd"); fi
  if [ -n "$resume" ]; then args+=(--resume "$resume"); fi

  if command -v setsid >/dev/null 2>&1; then
    setsid bash "${BASH_SOURCE[0]}" "${args[@]}" "$spec" >/dev/null 2>"$jobdir/launcher.err" </dev/null &
  else
    nohup bash "${BASH_SOURCE[0]}" "${args[@]}" "$spec" >/dev/null 2>"$jobdir/launcher.err" </dev/null &
  fi
  echo $! >"$jobdir/pid"
}

do_start() {
  do_launch
  if [ "$json_out" -eq 1 ]; then
    json_job "$jobdir" "$job" running ""
  else
    echo "JOB: $job"
    print_watch "$jobdir"
  fi
}

do_blocking_run() {
  do_launch
  [ "$json_out" -eq 1 ] || echo "JOB: $job"
  wait_job="$job"
  poll_timeout=$((hard_timeout + 60))
  do_wait
}

# -------------------------------------------------------------------- dispatch

if [ -n "$runner_jobdir" ]; then
  spec="${positionals[0]:-}"
  do_run
  exit 0
fi

case "$op" in
  "")
    if [ -n "$wait_job" ]; then op="wait"; else op="start"; spec="${positionals[0]:-}"; fi
    ;;
  start|run)  spec="${positionals[0]:-}" ;;
  resume)
    resume="${positionals[0]:-}"
    spec="${positionals[1]:-}"
    [ -n "$resume" ] || die "resume requires a session id: delegate.sh resume SESSION_ID \"<fix>\""
    op="start"
    ;;
  status|wait|cancel) wait_job="${positionals[0]:-$wait_job}" ;;
esac

case "$op" in
  start)  do_start ;;
  run)    do_blocking_run ;;
  status) do_status ;;
  wait)   do_wait ;;
  cancel) do_cancel ;;
  policy) do_policy ;;
  *)      die "unknown operation: $op" ;;
esac
