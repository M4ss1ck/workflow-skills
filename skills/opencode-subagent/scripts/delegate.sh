#!/usr/bin/env bash
# Supervise bounded OpenCode delegations: one Task, one or more Attempts, an
# append-only event history, independent verification, and durable decisions.
#
# Delegating:
#   delegate.sh start  [opts] "<task>"          launch Attempt 1 detached
#   delegate.sh run    [opts] "<task>"          launch and block until it ends
#   delegate.sh retry  TASK --reason R "<fix>"  new Attempt, same session by default
#   delegate.sh resume SESSION_ID "<fix>"       new Attempt on whatever Task owns SESSION_ID
#   delegate.sh cancel TASK [--keep-task]       stop the running Attempt
#
# Supervising:
#   delegate.sh status TASK                     current state, no blocking
#   delegate.sh wait   TASK [--poll-timeout S]
#   delegate.sh verify TASK [--label L] -- CMD  run + record independent verification
#   delegate.sh decide TASK DECISION --reason R accept|retry|reject|cancel|take_over|continue_waiting
#
# Inspecting:
#   delegate.sh list [--active] [--limit N]     recent Tasks
#   delegate.sh show TASK                       Task + attempts + verifications + events
#   delegate.sh attempts TASK
#   delegate.sh events TASK
#   delegate.sh logs TASK [ATTEMPT] [--stream report|request|raw|stderr|progress|result|meta|changed]
#   delegate.sh recover                         reconcile durable state after a crash
#   delegate.sh policy [off|explicit|auto]
#
# Options:
#   --model provider/model   worker model (overrides the configured one)
#   --cwd DIR                working tree for the worker
#   --resume SESSION_ID      continue a session (start/run)
#   --new-session            retry without reusing the Task's OpenCode session
#   --reason TEXT            why the supervisor is doing this (required: retry/reject/take_over)
#   --label TEXT             name a verification run
#   --timeout SECS           hard kill after SECS (default 1800)
#   --poll-timeout SECS      how long `wait` blocks before reporting RUNNING
#   --save-default           persist --model as the configured worker model
#   --json                   machine-readable output
#
# Exit codes: 0 finished  1 verification failed  2 usage/config  3 still running
#             4 incomplete turn (resume it)  124 timeout  127 missing CLI  130 cancelled
#
# Legacy forms still accepted: `delegate.sh [opts] "<task>"` and `delegate.sh --wait TASK`.
set -euo pipefail

provider="opencode"
agent_name="workflow-worker"
model_key="OPENCODE_SUBAGENT_MODEL"
policy_key="OPENCODE_SUBAGENT_DELEGATION_POLICY"
retention_key="OPENCODE_SUBAGENT_RETENTION_DAYS"
raw_retention_key="OPENCODE_SUBAGENT_RAW_RETENTION_DAYS"
default_policy="explicit"
default_retention_days=90
default_raw_retention_days=7
state_root="${XDG_STATE_HOME:-$HOME/.local/state}/workflow-skills/subagents"
conf_file="${XDG_CONFIG_HOME:-$HOME/.config}/workflow-skills/subagents.conf"
# Resolve our own path through symlinks: the script is reachable as
# ~/.local/bin/opencode-delegate and as a symlinked skills directory, and
# dirname of the *invocation* path would look for orchestration.sh next to the
# link instead of next to the script.
self_path="${BASH_SOURCE[0]}"
while [ -L "$self_path" ]; do
  self_link="$(readlink "$self_path")"
  case "$self_link" in
    /*) self_path="$self_link" ;;
    *)  self_path="$(dirname "$self_path")/$self_link" ;;
  esac
done
self_path="$(cd "$(dirname "$self_path")" && pwd)/$(basename "$self_path")"
skill_dir="$(cd "$(dirname "$self_path")/.." && pwd)"
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
stall_threshold="${DELEGATE_STALL_THRESHOLD:-300}"
runner_attemptdir=""
json_out=0
reason=""
label=""
stream="report"
new_session=0
only_active=0
limit=20
keep_task=0
skip_decision=0
task_id=""
task_dir=""
positionals=()

# shellcheck source=skills/opencode-subagent/scripts/orchestration.sh
. "$skill_dir/scripts/orchestration.sh"

# The header block, however long it grows: everything up to the first line of code.
usage() { sed -n '2,/^set -euo/p' "$self_path" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $1" >&2; exit "${2:-2}"; }

op=""
case "${1:-}" in
  start|run|retry|resume|status|wait|cancel|verify|decide|list|show|attempts|events|logs|recover|policy)
    op="$1"; shift ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)        shift; model="${1:?--model requires a value}" ;;
    --cwd)          shift; cwd="${1:?--cwd requires a path}" ;;
    --resume)       shift; resume="${1:?--resume requires a session id}" ;;
    --new-session)  new_session=1 ;;
    --reason)       shift; reason="${1:?--reason requires text}" ;;
    --label)        shift; label="${1:?--label requires text}" ;;
    --stream)       shift; stream="${1:?--stream requires a name}" ;;
    --timeout)      shift; hard_timeout="${1:?--timeout requires seconds}" ;;
    --save-default) save_default=1 ;;
    --wait)         shift; wait_job="${1:?--wait requires a task id}" ;;
    --poll-timeout) shift; poll_timeout="${1:?--poll-timeout requires seconds}" ;;
    --limit)        shift; limit="${1:?--limit requires a number}" ;;
    --active)       only_active=1 ;;
    --all)          only_active=0 ;;
    --keep-task)    keep_task=1 ;;
    --json)         json_out=1 ;;
    --__run)        shift; runner_attemptdir="${1:?internal flag requires an attempt dir}" ;;
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

conf_number() {
  local value
  value="$(conf_get "$1")"
  case "$value" in
    ''|*[!0-9]*) echo "$2" ;;
    *) echo "$value" ;;
  esac
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

# Retention favours the audit trail over the transient bulk. Orchestration
# history (task.json, events, requests, reports, verifications, decisions) is
# kept for RETENTION_DAYS; the large provider streams are dropped much sooner.
prune_state() {
  local keep_days raw_days d state
  keep_days="$(conf_number "$retention_key" "$default_retention_days")"
  raw_days="$(conf_number "$raw_retention_key" "$default_raw_retention_days")"
  for d in "$state_root"/task_*/; do
    [ -f "${d}task.json" ] || continue
    state="$(json_read "${d}task.json" '.state')"
    case "$state" in accepted|rejected|cancelled|taken_over) ;; *) continue ;; esac
    find "${d}attempts" -mindepth 2 -maxdepth 2 -type f \
      \( -name 'raw.jsonl' -o -name 'provider-progress.json' -o -name 'git-before.txt' -o -name 'git-after.txt' \) \
      -mtime "+$raw_days" -delete 2>/dev/null || true
    if find "${d}task.json" -mtime "+$keep_days" -print -quit 2>/dev/null | grep -q .; then
      rm -rf "${d%/}"
    fi
  done
}

# ------------------------------------------------------------------- job output

print_watch() {
  local dir="$1"
  echo "WATCH: tail -f $dir/raw.jsonl | jq -r '$watch_filter'"
  echo "STATUS: bash $skill_dir/scripts/delegate.sh status $(basename "$(dirname "$(dirname "$dir")")")"
  echo "PROGRESS: cat $dir/provider-progress.json"
  echo "REPORT: cat $dir/worker-report.txt"
  echo "PROVIDER_REPORT: cat $dir/worker-report.txt"
  echo "RESULT: cat $dir/result.json"
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

# A CLI-stream report is trusted only when the same invocation emitted a
# step_finish after it. This is the provider-final fallback when database
# inspection is unavailable or drifts.
stream_final_report() {
  jq -rs '
    ([to_entries[] | select(.value.type? == "step_finish") | .key] | last) as $finish
    | if $finish == null then empty
      else ([to_entries[] | select(.key < $finish and .value.type? == "text") | .value.part.text? // empty] | last // empty)
      end' "$1" 2>/dev/null || true
}

stream_finished() {
  jq -e -s 'any(.[]; .type? == "step_finish")' "$1" >/dev/null 2>&1
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
  local dir="$runner_attemptdir"
  local tdir attempt work
  tdir="$(cd "$dir/../.." && pwd)"
  attempt="$(basename "$dir")"
  work="${cwd:-$PWD}"
  local session cost report final_id db_report db_cost assistant_id assistant_finish
  local baseline_final_id="" baseline_assistant_id=""
  local baseline_final_ready=0 baseline_assistant_ready=0
  local runner_pid="" provider_complete=0 exit_code db_available=0 announced_session=0
  local transport worker class action
  printf '%s\n' "${BASHPID:-$$}" >"$dir/pid"
  persist_process_identity "$dir/process.json" "${BASHPID:-$$}"

  stop_provider() {
    local i
    if [ -n "$runner_pid" ]; then
      kill -TERM -- "-$runner_pid" 2>/dev/null || kill -TERM "$runner_pid" 2>/dev/null || true
      for i in {1..10}; do
        kill -0 "$runner_pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -KILL -- "-$runner_pid" 2>/dev/null || kill -KILL "$runner_pid" 2>/dev/null || true
      wait "$runner_pid" 2>/dev/null || true
    fi
    exit 130
  }
  trap stop_provider TERM INT

  build_cmd
  if provider_db_available; then db_available=1; fi
  if [ "$db_available" -eq 1 ] && [ -n "$resume" ]; then
    if baseline_final_id="$(provider_final_id "$resume")"; then baseline_final_ready=1; fi
    if baseline_assistant_id="$(provider_latest_assistant_id "$resume")"; then baseline_assistant_ready=1; fi
  fi

  # Publish the session as soon as it exists: a supervisor that cancels or
  # crashes mid-attempt still needs an id to resume from.
  announce_session() {
    [ "$announced_session" -eq 0 ] || return 0
    announced_session=1
    lock_acquire "$tdir"
    if [ "$(json_read "$tdir/task.json" '.current_attempt')" != "$attempt" ] \
      || task_is_terminal "$tdir" || [ -f "$dir/result.json" ]; then
      lock_release
      return 0
    fi
    task_update "$tdir" '.session_id = $session' --arg session "$1"
    event_append "$tdir" session_discovered \
      "$(jq -c -n --arg attempt "$attempt" --arg session "$1" --argjson reused "$([ -n "$resume" ] && echo true || echo false)" \
        '{attempt: $attempt, session_id: $session, reused: $reused}')"
    lock_release
  }

  set +e
  if [ "$db_available" -eq 1 ] && command -v setsid >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      setsid timeout "$hard_timeout" "${cmd[@]}" "$spec" >"$dir/raw.jsonl" 2>"$dir/stderr.log" &
    else
      setsid "${cmd[@]}" "$spec" >"$dir/raw.jsonl" 2>"$dir/stderr.log" &
    fi
    runner_pid=$!
    printf '%s\n' "$runner_pid" >"$dir/provider.pid"
    persist_process_identity "$dir/provider-process.json" "$runner_pid"
    session="$resume"
    if [ -n "$session" ]; then announce_session "$session"; fi

    while kill -0 "$runner_pid" 2>/dev/null; do
      if [ -z "$session" ]; then
        session="$(stream_session "$dir/raw.jsonl")"
        if [ -n "$session" ]; then announce_session "$session"; fi
      fi
      if [ -n "$session" ]; then
        snapshot_provider_progress "$dir" "$session"
        if final_id="$(provider_final_id "$session")" \
          && [ -n "$final_id" ] \
          && { [ -z "$resume" ] || { [ "$baseline_final_ready" -eq 1 ] && [ "$final_id" != "$baseline_final_id" ]; }; } \
          && db_report="$(provider_report "$session" "$final_id")"; then
          printf '%s\n' "$db_report" >"$dir/worker-report.txt"
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
    run_with_timeout "${cmd[@]}" "$spec" >"$dir/raw.jsonl" 2>"$dir/stderr.log" &
    runner_pid=$!
    printf '%s\n' "$runner_pid" >"$dir/provider.pid"
    persist_process_identity "$dir/provider-process.json" "$runner_pid"
    wait "$runner_pid"
    exit_code=$?
  fi
  set -e
  runner_pid=""

  session="${resume:-$(stream_session "$dir/raw.jsonl")}"
  [ -z "$session" ] || announce_session "$session"
  cost="$(jq -rs '[.[] | select(.type? == "step_finish") | .part.cost? // empty] | last // empty' "$dir/raw.jsonl" 2>/dev/null || true)"
  report="$(stream_final_report "$dir/raw.jsonl")"

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

  if [ "$exit_code" -eq 0 ] && [ "$provider_complete" -eq 0 ] && ! stream_finished "$dir/raw.jsonl"; then
    exit_code=4
    report="${report}"$'\n\n'"ERROR: OpenCode exited before producing a provider-final response. Resume this session."
  fi

  if [ -z "$report" ]; then
    report="$(tail -c 2000 "$dir/stderr.log"; tail -c 2000 "$dir/raw.jsonl")"
  fi
  printf '%s\n' "$report" >"$dir/worker-report.txt"
  record_changed_files "$dir" "$work"

  case "$exit_code" in
    0)   transport="finished" ;;
    4)   transport="incomplete" ;;
    124) transport="timeout" ;;
    130) transport="cancelled" ;;
    *)   transport="failed" ;;
  esac
  worker="$(parse_worker_report "$dir/worker-report.txt" | jq -r '.worker')"
  IFS='|' read -r class action <<<"$(classify_attempt "$exit_code" "$worker" "$session" "$dir/stderr.log")"

  lock_acquire "$tdir"
  if [ ! -f "$dir/result.json" ]; then
    attempt_write_result "$dir" "${session:-}" "${cost:-}" "" "$exit_code" "$transport" "$class" "$action"
    attempt_finalize "$tdir" "$attempt" >/dev/null
  fi
  lock_release
  trap - TERM INT
}

# ------------------------------------------------------------------ resolution

require_task() {
  local id="${1:-}"
  [ -n "$id" ] || die "missing task id (see: delegate.sh list)"
  if task_exists "$id"; then
    task_id="$id"
    task_dir="$state_root/$id"
    return 0
  fi
  if legacy_job_exists "$id"; then
    task_id="$id"
    task_dir="$state_root/$id"
    return 1
  fi
  die "unknown task: $id (looked in $state_root; see: delegate.sh list)"
}

# The pre-Task layout had no task.json. Read those directories, clearly labelled,
# rather than deleting them or pretending they are Tasks.
legacy_emit() {
  local dir="$state_root/$task_id" st code
  st="$(cat "$dir/status" 2>/dev/null || echo "running")"
  code="${st##* }"
  case "$code" in ''|*[!0-9]*) code=3 ;; esac
  if [ "$json_out" -eq 1 ]; then
    jq -n --arg id "$task_id" --arg state "${st%% *}" --arg dir "$dir" --argjson code "$code" \
      --rawfile report "$([ -f "$dir/result.txt" ] && echo "$dir/result.txt" || echo /dev/null)" \
      '{task_id: $id, job_id: $id, legacy: true, state: $state, exit_code: $code,
        state_dir: $dir, report: $report,
        note: "pre-Task job directory; no attempt/event history exists for it"}'
  else
    echo "LEGACY JOB: $task_id (pre-Task layout; no attempt or event history)"
    cat "$dir/result.txt" 2>/dev/null || echo "STATE: ${st%% *}"
  fi
  exit "$code"
}

task_exit_code() {
  local dir="$1" state current
  state="$(task_state "$dir")"
  [ "$state" != "cancelled" ] || { echo 130; return 0; }
  current="$(json_read "$dir/task.json" '.current_attempt')"
  if [ -z "$current" ] || [ "$current" = "null" ]; then echo 0; return 0; fi
  if [ ! -f "$dir/attempts/$current/result.json" ]; then echo 3; return 0; fi
  json_read "$dir/attempts/$current/result.json" '.exit_code // 0'
}

attempt_running() {
  local dir="$1" current
  current="$(json_read "$dir/task.json" '.current_attempt')"
  [ -n "$current" ] && [ "$current" != "null" ] || return 1
  [ ! -f "$dir/attempts/$current/result.json" ] || return 1
  return 0
}

# ------------------------------------------------------------------ operations

emit_status() {
  local code
  lock_acquire "$task_dir"
  if [ "$json_out" -eq 1 ]; then json_status "$task_dir"; else
    local adir
    if attempt_running "$task_dir"; then
      adir="$task_dir/attempts/$(json_read "$task_dir/task.json" '.current_attempt')"
      attempt_liveness "$adir" | jq -r '"RUNNING (elapsed \(.elapsed_seconds)s, idle \(.idle_seconds // "?")s, alive=\(.process_alive), possibly_stalled=\(.possibly_stalled))"'
      render_status "$task_dir"
      print_watch "$adir"
    else
      render_status "$task_dir"
    fi
  fi
  code="$(task_exit_code "$task_dir")"
  lock_release
  exit "$code"
}

do_status() {
  require_task "${positionals[0]:-$wait_job}" || legacy_emit
  emit_status
}

do_wait() {
  require_task "${positionals[0]:-$wait_job}" || legacy_emit
  local end=$((SECONDS + poll_timeout))
  while attempt_running "$task_dir"; do
    if [ "$SECONDS" -ge "$end" ]; then break; fi
    sleep "$poll_interval"
  done
  emit_status
}

do_cancel() {
  require_task "${positionals[0]:-$wait_job}" || legacy_emit
  local current adir pid i
  lock_acquire "$task_dir"
  if task_is_terminal "$task_dir"; then lock_release; emit_status; fi
  current="$(json_read "$task_dir/task.json" '.current_attempt')"
  if attempt_running "$task_dir"; then
    adir="$task_dir/attempts/$current"
    pid="$(attempt_pid "$adir")"
    if [ -n "$pid" ] && attempt_alive "$adir"; then
      attempt_signal "$adir" TERM
      for i in {1..30}; do
        attempt_alive "$adir" || break
        sleep 0.1
      done
      if attempt_alive "$adir"; then
        attempt_signal "$adir" KILL
      fi
    fi
    record_changed_files "$adir" "$(json_read "$task_dir/task.json" '.cwd')"
    printf '%s\n' "Cancelled by the supervisor before the worker reported." >"$adir/worker-report.txt"
    attempt_write_result "$adir" "$(json_read "$task_dir/task.json" '.session_id // ""')" "" "" 130 cancelled cancelled none
    attempt_finalize "$task_dir" "$current" >/dev/null
  elif [ -n "$current" ] && [ "$current" != "null" ] \
    && [ "$(task_state "$task_dir")" = "running" ]; then
    # Completion won the result-file race but had not yet folded its result.
    attempt_finalize "$task_dir" "$current" >/dev/null
  fi
  if [ "$keep_task" -eq 0 ]; then
    task_update "$task_dir" \
      '.state = "cancelled" | .outcome.supervisor = "cancelled" | .recommended_action = "none"
       | .disposition = {decision: "cancel", reason: $reason, at: $_now}' \
      --arg reason "${reason:-cancelled by the supervisor}"
    event_append "$task_dir" task_cancelled \
      "$(jq -c -n --arg reason "${reason:-cancelled by the supervisor}" '{reason: $reason}')"
  fi
  lock_release
  emit_status
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
      --argjson retention "$(conf_number "$retention_key" "$default_retention_days")" \
      --argjson raw_retention "$(conf_number "$raw_retention_key" "$default_raw_retention_days")" \
      '{delegation_policy: $policy, worker_model: (if $model == "" then null else $model end),
        agent: $agent, conf_file: $conf,
        retention_days: $retention, raw_retention_days: $raw_retention}'
  else
    echo "DELEGATION_POLICY: $current"
    echo "WORKER_MODEL: ${worker:-none}"
    echo "CONF: $conf_file"
    echo "RETENTION_DAYS: $(conf_number "$retention_key" "$default_retention_days")"
    echo "RAW_RETENTION_DAYS: $(conf_number "$raw_retention_key" "$default_raw_retention_days")"
  fi
}

# ---------------------------------------------------------------------- launch

preflight() {
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
  prune_state
}

task_title() {
  printf '%s' "$1" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' | cut -c1-100
}

# spawn_attempt ATTEMPT_DIR — detach the runner and record its pid.
spawn_attempt() {
  local adir="$1" pid
  local args=(--__run "$adir" --timeout "$hard_timeout" --model "$model")
  if [ -n "$cwd" ]; then args+=(--cwd "$cwd"); fi
  if [ -n "$resume" ]; then args+=(--resume "$resume"); fi
  git_porcelain "${cwd:-$PWD}" >"$adir/git-before.txt"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$self_path" "${args[@]}" "$spec" >/dev/null 2>"$adir/launcher.err" </dev/null &
  else
    nohup bash "$self_path" "${args[@]}" "$spec" >/dev/null 2>"$adir/launcher.err" </dev/null &
  fi
  pid=$!
  printf '%s\n' "$pid" >"$adir/pid"
  persist_process_identity "$adir/process.json" "$pid"
}

do_launch() {
  [ -n "$spec" ] || die "missing task spec"
  preflight

  task_id="task_$(date +%Y%m%d-%H%M%S)-$RANDOM"
  task_dir="$state_root/$task_id"
  while ! mkdir "$task_dir" 2>/dev/null; do
    task_id="task_$(date +%Y%m%d-%H%M%S)-$RANDOM"
    task_dir="$state_root/$task_id"
  done

  lock_acquire "$task_dir"
  task_create "$task_dir" "$task_id" "${cwd:-$PWD}" "$model" "$hard_timeout" "$(task_title "$spec")"

  local adir
  adir="$(attempt_create "$task_dir" 1 initial "" "$resume" "$reason" "$spec")"
  attempt_register "$task_dir" attempt_001
  spawn_attempt "$adir"
  lock_release
}

do_retry() {
  require_task "${positionals[0]:-}" || die "cannot retry a pre-Task job directory; start a new task instead"
  spec="${positionals[1]:-}"
  [ -n "$spec" ] || die "retry requires a correction: delegate.sh retry TASK --reason R \"<correction>\""
  [ -n "$reason" ] || die "retry requires --reason (it becomes the durable supervisor decision)"

  preflight

  local prev index session adir
  lock_acquire "$task_dir"
  ! task_is_terminal "$task_dir" \
    || die "task $task_id is $(task_state "$task_dir"); it cannot be retried"
  ! attempt_running "$task_dir" \
    || die "attempt $(json_read "$task_dir/task.json" '.current_attempt') is still running; wait for it or: delegate.sh cancel $task_id --keep-task"
  prev="$(json_read "$task_dir/task.json" '.current_attempt')"
  index=$(( $(json_read "$task_dir/task.json" '.attempt_count') + 1 ))
  cwd="${cwd:-$(json_read "$task_dir/task.json" '.cwd')}"
  session="$(json_read "$task_dir/task.json" '.session_id // ""')"
  [ "$session" != "null" ] || session=""
  if [ "$new_session" -eq 1 ]; then session=""; fi
  if [ -n "$resume" ]; then session="$resume"; fi
  resume="$session"

  if [ "$skip_decision" -eq 0 ]; then
    record_decision "$task_dir" retry "$reason" "$prev"
  fi

  adir="$(attempt_create "$task_dir" "$index" retry "$prev" "$session" "$reason" "$spec")"
  attempt_register "$task_dir" "$(attempt_id_for "$index")"
  spawn_attempt "$adir"
  lock_release
}

# The legacy entrypoint: resume by session id. Reattach to whatever Task owns
# that session so the correction lands in the same audit trail.
do_resume() {
  local session="${positionals[0]:-}"
  spec="${positionals[1]:-}"
  [ -n "$session" ] || die "resume requires a session id: delegate.sh resume SESSION_ID \"<fix>\""
  [ -n "$spec" ] || die "resume requires a correction: delegate.sh resume SESSION_ID \"<fix>\""

  local d found="" candidate
  for d in "$state_root"/task_*/; do
    [ -f "${d}task.json" ] || continue
    [ "$(json_read "${d}task.json" '.session_id')" = "$session" ] || continue
    task_is_terminal "${d%/}" && continue
    candidate="$(basename "${d%/}")"
    [ -z "$found" ] || die "session $session belongs to multiple open Tasks ($found, $candidate); retry one by Task id"
    found="$candidate"
  done

  if [ -n "$found" ]; then
    positionals=("$found" "$spec")
    # A `decide retry` immediately before this already carries the reasoning;
    # don't record a second, emptier decision for the same correction.
    if [ -z "$reason" ] \
      && [ "$(json_read "$state_root/$found/task.json" '.disposition.decision // ""')" = "retry" ]; then
      reason="$(json_read "$state_root/$found/task.json" '.disposition.reason // ""')"
      skip_decision=1
    fi
    reason="${reason:-resumed by session id}"
    do_retry
    return
  fi

  resume="$session"
  do_launch
}

emit_launch() {
  if [ "$json_out" -eq 1 ]; then
    json_status "$task_dir"
  else
    echo "TASK: $task_id"
    echo "JOB: $task_id"
    echo "ATTEMPT: $(json_read "$task_dir/task.json" '.current_attempt')"
    print_watch "$task_dir/attempts/$(json_read "$task_dir/task.json" '.current_attempt')"
  fi
}

do_start() { do_launch; emit_launch; }

do_blocking_run() {
  do_launch
  if [ "$json_out" -ne 1 ]; then
    echo "TASK: $task_id"
    echo "JOB: $task_id"
  fi
  poll_timeout=$((hard_timeout + 60))
  positionals=("$task_id")
  wait_job="$task_id"
  do_wait
}

# ---------------------------------------------------------------- verification
# Runs outside the worker's OpenCode turn, by the supervisor, and is recorded
# whether it passes or fails. A worker claiming its tests pass is not this.

# Re-executable and still legible in the audit record, unlike printf %q.
shell_quote() {
  local a out=""
  for a in "$@"; do
    case "$a" in
      ''|*[!A-Za-z0-9_./=:@,+-]*) out+="'${a//\'/\'\\\'\'}' " ;;
      *) out+="$a " ;;
    esac
  done
  printf '%s' "${out% }"
}

do_verify() {
  require_task "${positionals[0]:-}" || die "cannot verify a pre-Task job directory"
  local cmdline
  if [ "${#positionals[@]}" -gt 2 ]; then
    cmdline="$(shell_quote "${positionals[@]:1}")"
  else
    cmdline="${positionals[1]:-}"
  fi
  [ -n "$cmdline" ] || die "verify requires a command: delegate.sh verify TASK -- pnpm test"
  lock_acquire "$task_dir"
  ! attempt_running "$task_dir" \
    || die "attempt $(json_read "$task_dir/task.json" '.current_attempt') is still running; verification must run outside the worker's turn"

  local work vid vdir started ended code result
  work="${cwd:-$(json_read "$task_dir/task.json" '.cwd')}"
  vdir="$task_dir/verifications"
  mkdir -p "$vdir"
  vid="$(verification_next_id "$task_dir")"
  task_update "$task_dir" '.verification_count = (.verification_count + 1)'
  event_append "$task_dir" verification_started \
    "$(jq -c -n --arg id "$vid" --arg cmd "$cmdline" --arg cwd "$work" '{verification: $id, command: $cmd, cwd: $cwd}')"

  started="$(now_iso)"
  set +e
  ( cd "$work" && bash -c "$cmdline" ) >"$vdir/$vid.stdout" 2>"$vdir/$vid.stderr"
  code=$?
  set -e
  ended="$(now_iso)"
  case "$code" in
    0)       result="passed" ;;
    126|127) result="error" ;;
    *)       result="failed" ;;
  esac

  jq -n \
    --arg id "$vid" \
    --arg attempt "$(json_read "$task_dir/task.json" '.current_attempt')" \
    --arg command "$cmdline" \
    --arg cwd "$work" \
    --arg label "$label" \
    --arg started "$started" \
    --arg ended "$ended" \
    --argjson code "$code" \
    --arg result "$result" \
    --arg stdout_file "$vdir/$vid.stdout" \
    --arg stderr_file "$vdir/$vid.stderr" \
    --arg stdout_tail "$(tail -c 4000 "$vdir/$vid.stdout" 2>/dev/null || true)" \
    --arg stderr_tail "$(tail -c 4000 "$vdir/$vid.stderr" 2>/dev/null || true)" \
    '{verification_id: $id, attempt: $attempt, label: (if $label == "" then null else $label end),
      command: $command, cwd: $cwd, started_at: $started, ended_at: $ended,
      exit_code: $code, result: $result,
      stdout_file: $stdout_file, stderr_file: $stderr_file,
      stdout_tail: $stdout_tail, stderr_tail: $stderr_tail}' \
    | write_atomic "$vdir/$vid.json"

  task_update "$task_dir" \
    '.outcome.verification = $result
     | .last_verification = {id: $id, command: $command, result: $result, exit_code: $code, at: $_now}
     | .recommended_action = (if $result == "passed" then "inspect_diff"
                              elif $result == "error" then "repair_infrastructure"
                              else "resume_same_session" end)
     | .failure_class = (if $result == "passed" then .failure_class
                         elif $result == "error" then "verification_error"
                         else "verification_failed" end)' \
    --arg result "$result" --arg id "$vid" --arg command "$cmdline" --argjson code "$code"
  event_append "$task_dir" "verification_$result" \
    "$(jq -c -n --arg id "$vid" --arg cmd "$cmdline" --argjson code "$code" \
      --arg tail "$(tail -c 2000 "$vdir/$vid.stdout" 2>/dev/null || true)" \
      '{verification: $id, command: $cmd, exit_code: $code, output_tail: $tail}')"
  lock_release

  if [ "$json_out" -eq 1 ]; then
    cat "$vdir/$vid.json"
  else
    echo "VERIFICATION: $vid $result (exit $code)"
    echo "COMMAND: $cmdline"
    echo "CWD: $work"
    echo "--- OUTPUT ---"
    tail -c 4000 "$vdir/$vid.stdout" 2>/dev/null || true
    tail -c 4000 "$vdir/$vid.stderr" 2>/dev/null || true
  fi
  [ "$result" = "passed" ] && return 0
  [ "$result" != "error" ] || exit 2
  exit 1
}

# ------------------------------------------------------------------- decisions

# record_decision TASKDIR DECISION REASON [ATTEMPT] — caller holds the lock.
record_decision() {
  local dir="$1" decision="$2" why="$3" attempt="${4:-}"
  task_update "$dir" \
    '.disposition = {decision: $decision, reason: $reason, at: $_now}' \
    --arg decision "$decision" --arg reason "$why"
  event_append "$dir" supervisor_decision \
    "$(jq -c -n --arg decision "$decision" --arg reason "$why" --arg attempt "$attempt" \
      --arg verification "$(json_read "$dir/task.json" '.outcome.verification')" \
      --arg worker "$(json_read "$dir/task.json" '.outcome.worker')" \
      '{decision: $decision, reason: $reason,
        attempt: (if $attempt == "" then null else $attempt end),
        worker_outcome_at_decision: $worker,
        verification_at_decision: $verification}')"
}

do_decide() {
  require_task "${positionals[0]:-}" || die "cannot record a decision on a pre-Task job directory"
  local decision="${positionals[1]:-}"
  case "$decision" in
    accept|retry|reject|cancel|take_over|continue_waiting) ;;
    "") die "decide requires a decision: accept|retry|reject|cancel|take_over|continue_waiting" ;;
    *)  die "unknown decision: $decision (want accept|retry|reject|cancel|take_over|continue_waiting)" ;;
  esac
  case "$decision" in
    retry|reject|take_over)
      [ -n "$reason" ] || die "--reason is required for '$decision'" ;;
  esac
  if [ "$decision" = "cancel" ]; then
    positionals=("$task_id")
    do_cancel
    return
  fi
  lock_acquire "$task_dir"
  case "$decision" in
    accept|reject|take_over)
      ! attempt_running "$task_dir" \
        || die "attempt $(json_read "$task_dir/task.json" '.current_attempt') is still running; wait for it or cancel it first" ;;
  esac
  case "$(task_state "$task_dir"):$decision" in
    accepted:*|cancelled:*|taken_over:*|rejected:accept|rejected:reject|rejected:retry|rejected:continue_waiting)
      die "task $task_id is $(task_state "$task_dir"); decision '$decision' is not allowed" ;;
  esac

  record_decision "$task_dir" "$decision" "$reason" "$(json_read "$task_dir/task.json" '.current_attempt')"
  case "$decision" in
    accept)
      task_update "$task_dir" '.state = "accepted" | .outcome.supervisor = "accepted" | .recommended_action = "none"'
      event_append "$task_dir" task_accepted \
        "$(jq -c -n --arg reason "$reason" --arg verification "$(json_read "$task_dir/task.json" '.outcome.verification')" \
          '{reason: $reason, verification_at_acceptance: $verification}')" ;;
    reject)
      task_update "$task_dir" '.state = "rejected" | .outcome.supervisor = "rejected" | .recommended_action = "take_over"'
      event_append "$task_dir" task_rejected "$(jq -c -n --arg reason "$reason" '{reason: $reason}')" ;;
    take_over)
      task_update "$task_dir" '.state = "taken_over" | .outcome.supervisor = "taken_over" | .recommended_action = "none"'
      event_append "$task_dir" supervisor_takeover "$(jq -c -n --arg reason "$reason" '{reason: $reason}')" ;;
    retry)
      task_update "$task_dir" '.outcome.supervisor = "retry" | .recommended_action = "resume_same_session"' ;;
    continue_waiting)
      task_update "$task_dir" '.outcome.supervisor = "continue_waiting"' ;;
  esac
  lock_release
  emit_status
}

# ------------------------------------------------------------------ inspection

do_list() {
  local d rows
  rows="$(
    for d in "$state_root"/task_*/; do
      [ -f "${d}task.json" ] || continue
      jq -c '{task_id, title, state, outcome, attempt_count, current_attempt,
              session_id, model, cwd, created_at, updated_at,
              failure_class, recommended_action, verification_count}' "${d}task.json" 2>/dev/null || true
    done | jq -s --argjson active "$only_active" --argjson limit "$limit" \
      'sort_by(.updated_at) | reverse
       | (if $active == 1 then map(select(.state == "running" or .state == "awaiting_supervisor")) else . end)
       | .[0:$limit]'
  )"
  if [ "$json_out" -eq 1 ]; then
    echo "$rows"
  else
    if [ "$(echo "$rows" | jq 'length')" -eq 0 ]; then echo "no tasks in $state_root"; return 0; fi
    echo "$rows" | jq -r '
      (["TASK","STATE","WORKER","VERIF","ATT","UPDATED","TITLE"] | @tsv),
      (.[] | [.task_id, .state, .outcome.worker, .outcome.verification,
              (.attempt_count | tostring), .updated_at, (.title // "-")] | @tsv)' \
      | column -t -s "$(printf '\t')" 2>/dev/null \
      || echo "$rows" | jq -r '.[] | "\(.task_id)  \(.state)  \(.outcome.worker)  \(.title // "-")"'
  fi
}

do_show() {
  require_task "${positionals[0]:-}" || legacy_emit
  lock_acquire "$task_dir"
  if [ "$json_out" -eq 1 ]; then json_task "$task_dir" --full; lock_release; return 0; fi
  json_task "$task_dir" --full | jq -r '
    "TASK: \(.task_id)",
    "TITLE: \(.title // "-")",
    "STATE: \(.state)",
    "CWD: \(.cwd)",
    "MODEL: \(.model)   AGENT: \(.agent)",
    "SESSION: \(.session_id // "unknown")",
    "OUTCOME: transport=\(.outcome.transport) worker=\(.outcome.worker) verification=\(.outcome.verification) supervisor=\(.outcome.supervisor)",
    (if .failure_class then "FAILURE: \(.failure_class)" else empty end),
    "NEXT: \(.recommended_action)",
    (if .disposition then "DISPOSITION: \(.disposition.decision) — \(.disposition.reason // "no reason recorded") (\(.disposition.at))" else empty end),
    "",
    "ATTEMPTS (\(.attempt_count)):",
    (.attempts[] |
      "  \(.attempt_id) \(.kind)\(if .retry_of then " of \(.retry_of)" else "" end)"
      + " session=\(.session_id // .requested_session // "-")"
      + " transport=\(.transport) worker=\(.worker)"
      + "\(if .failure_class then " failure=\(.failure_class)" else "" end)"
      + "\(if .authoritative == false then " [stale]" else "" end)"),
    "",
    "VERIFICATIONS (\(.verifications | length)):",
    (.verifications[] | "  \(.verification_id) \(.result) exit=\(.exit_code) — \(.command)"),
    "",
    "HISTORY:",
    (.events[] | "  \(.seq | tostring) \(.ts) \(.type)"
      + "\(if .attempt then " attempt=\(.attempt)" else "" end)"
      + "\(if .verification then " \(.verification)" else "" end)"
      + "\(if .command then " command=\(.command)" else "" end)"
      + "\(if .decision then " decision=\(.decision)" else "" end)"
      + "\(if .question then " question=\(.question)" else "" end)"
      + "\(if .reason then " — \(.reason)" else "" end)")'
  lock_release
}

do_attempts() {
  require_task "${positionals[0]:-}" || legacy_emit
  local a out
  lock_acquire "$task_dir"
  out="$(for a in "$task_dir"/attempts/attempt_*/; do [ -d "$a" ] && json_attempt "${a%/}"; done | jq -s '.')"
  if [ "$json_out" -eq 1 ]; then echo "$out"; else
    echo "$out" | jq -r '.[] |
      "\(.attempt_id) \(.kind)\(if .retry_of then " (retry of \(.retry_of))" else "" end)",
      "  request: \(.attempt_dir)/request.md",
      "  session: \(.session_id // .requested_session // "-")  reused=\(.session_reused)",
      "  transport=\(.transport) worker=\(.worker) exit=\(.exit_code // "-")",
      "  reason: \(.reason // "-")",
      ""'
  fi
  lock_release
}

do_events() {
  require_task "${positionals[0]:-}" || legacy_emit
  lock_acquire "$task_dir"
  if [ "$json_out" -eq 1 ]; then
    jq -s '.' "$task_dir/events.jsonl"
  else
    jq -r '"\(.seq)\t\(.ts)\t\(.type)\t\(. | del(.seq, .ts, .type) | tojson)"' "$task_dir/events.jsonl"
  fi
  lock_release
}

do_logs() {
  require_task "${positionals[0]:-}" || legacy_emit
  local attempt file
  attempt="${positionals[1]:-$(json_read "$task_dir/task.json" '.current_attempt')}"
  [ -n "$attempt" ] && [ "$attempt" != "null" ] || die "task $task_id has no attempts yet"
  [ -d "$task_dir/attempts/$attempt" ] || die "unknown attempt: $attempt (see: delegate.sh attempts $task_id)"
  case "$stream" in
    report)   file="worker-report.txt" ;;
    request)  file="request.md" ;;
    raw)      file="raw.jsonl" ;;
    stderr)   file="stderr.log" ;;
    progress) file="provider-progress.json" ;;
    result)   file="result.json" ;;
    meta)     file="meta.json" ;;
    changed)  file="changed-files.txt" ;;
    *) die "unknown stream: $stream (want report|request|raw|stderr|progress|result|meta|changed)" ;;
  esac
  [ -f "$task_dir/attempts/$attempt/$file" ] \
    || die "no $stream for $task_id/$attempt (retention may have pruned it)"
  cat "$task_dir/attempts/$attempt/$file"
}

do_recover() {
  local d id out results=()
  for d in "$state_root"/task_*/; do
    [ -f "${d}task.json" ] || continue
    id="$(basename "${d%/}")"
    out="$(reconcile_task "${d%/}")"
    results+=("$(jq -c -n --arg id "$id" --arg finding "$out" \
      --arg state "$(task_state "${d%/}")" \
      --arg attempt "$(json_read "${d}task.json" '.current_attempt')" \
      '{task_id: $id, reconciliation: $finding, state: $state, current_attempt: $attempt}')")
  done
  if [ "${#results[@]}" -eq 0 ]; then
    [ "$json_out" -eq 1 ] && echo '[]' || echo "no tasks in $state_root"
    return 0
  fi
  if [ "$json_out" -eq 1 ]; then
    printf '%s\n' "${results[@]}" | jq -s '.'
  else
    printf '%s\n' "${results[@]}" | jq -r '"\(.task_id)  \(.reconciliation)  state=\(.state)  attempt=\(.current_attempt // "-")"'
  fi
}

# -------------------------------------------------------------------- dispatch

if [ -n "$runner_attemptdir" ]; then
  spec="${positionals[0]:-}"
  do_run
  exit 0
fi

case "$op" in
  "")
    if [ -n "$wait_job" ]; then op="wait"; else op="start"; spec="${positionals[0]:-}"; fi
    ;;
  start|run) spec="${positionals[0]:-}" ;;
esac

case "$op" in
  start)    do_start ;;
  run)      do_blocking_run ;;
  retry)    do_retry; emit_launch ;;
  resume)   do_resume; emit_launch ;;
  status)   do_status ;;
  wait)     do_wait ;;
  cancel)   do_cancel ;;
  verify)   do_verify ;;
  decide)   do_decide ;;
  list)     do_list ;;
  show)     do_show ;;
  attempts) do_attempts ;;
  events)   do_events ;;
  logs)     do_logs ;;
  recover)  do_recover ;;
  policy)   do_policy ;;
  *)        die "unknown operation: $op" ;;
esac
