#!/usr/bin/env bash
# Durable Task / Attempt / Event state for the OpenCode delegation supervisor.
#
# Sourced by delegate.sh. Not runnable on its own.
#
# Layout, under $state_root:
#
#   task_<id>/
#     task.json                  current authoritative state (atomic replace)
#     events.jsonl               append-only orchestration history
#     verifications/ver_NNN.{json,stdout,stderr}
#     attempts/attempt_NNN/
#       request.md               the exact text sent to the worker
#       meta.json                launch inputs (model, cwd, session, retry_of, reason)
#       result.json              transport + worker outcome, written when the run ends
#       raw.jsonl stderr.log provider-progress.json worker-report.txt
#       changed-files.txt git-before.txt git-after.txt pid process.json
#       provider.pid provider-process.json launcher.err
#
# Invariants:
#   - task.json is the only cheap-to-query current state; it is never appended to,
#     only replaced atomically.
#   - events.jsonl is append-only. Nothing rewrites history.
#   - Only the attempt named by task.current_attempt may move the Task forward.
#     A stale detached attempt that finishes later records itself and stops.

# shellcheck shell=bash

schema_version=2
lock_held=""
lock_token=""

# ------------------------------------------------------------------ primitives

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

process_start_time() {
  local pid="$1"
  [ -r "/proc/$pid/stat" ] || return 0
  sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}'
}

process_state() {
  local pid="$1"
  [ -r "/proc/$pid/stat" ] || return 0
  sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $1}'
}

persist_process_identity() {
  local dest="$1" pid="$2"
  jq -n --argjson pid "$pid" --arg boot "$(boot_id)" --arg start "$(process_start_time "$pid")" \
    '{pid: $pid, boot_id: (if $boot == "" then null else $boot end),
      start_time: (if $start == "" then null else $start end)}' | write_atomic "$dest"
}

process_identity_alive() {
  local file="$1" fallback_pid="${2:-}" pid stored_boot stored_start current_boot current_start
  [ -f "$file" ] || return 1
  pid="$(json_read "$file" '.pid // empty')"
  pid="${pid:-$fallback_pid}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  [ "$(process_state "$pid")" != "Z" ] || return 1
  stored_boot="$(json_read "$file" '.boot_id // empty')"
  stored_start="$(json_read "$file" '.start_time // empty')"
  current_boot="$(boot_id)"
  current_start="$(process_start_time "$pid")"
  [ -z "$stored_boot" ] || [ -z "$current_boot" ] || [ "$stored_boot" = "$current_boot" ] || return 1
  [ -z "$stored_start" ] || [ -z "$current_start" ] || [ "$stored_start" = "$current_start" ] || return 1
  return 0
}

# Replace a file in one step. Refuses to install an empty payload so a failed
# producer (jq erroring mid-pipeline) cannot truncate live state.
write_atomic() {
  local dest="$1" tmp="$1.tmp.$$"
  cat >"$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$dest"
}

# Coarse per-task mutex. mkdir is atomic on every filesystem we care about. The
# owner PID is published immediately, followed by a boot/process-start
# fingerprint. A lock is reaped only when that owner is no longer the same live
# process; elapsed wall time alone never breaks a lock with a published owner.
lock_acquire() {
  local dir="$1/.lock" owner age self="${BASHPID:-$$}"
  if [ -n "$lock_held" ]; then
    [ "$lock_held" = "$dir" ] || { echo "BUG: attempted to nest locks for different Tasks" >&2; return 1; }
    return 0
  fi
  while ! mkdir "$dir" 2>/dev/null; do
    owner="$(cat "$dir/owner.pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      if [ -f "$dir/process.json" ] && ! process_identity_alive "$dir/process.json" "$owner"; then
        rm -rf "$dir" 2>/dev/null || true
        continue
      fi
      sleep 0.1
      continue
    fi
    age="$(file_age_seconds "$dir")"
    if [ -n "$owner" ] || { [ "$age" != "null" ] && [ "$age" -ge 30 ]; }; then
      rm -rf "$dir" 2>/dev/null || true
      continue
    fi
    sleep 0.1
  done
  lock_token="$self-$(now_epoch)-$RANDOM"
  printf '%s\n' "$self" >"$dir/owner.pid"
  printf '%s\n' "$lock_token" >"$dir/owner.token"
  persist_process_identity "$dir/process.json" "$self"
  lock_held="$dir"
}

lock_release() {
  local held="$lock_held"
  if [ -n "$held" ] && [ "$(cat "$held/owner.token" 2>/dev/null || true)" = "$lock_token" ]; then
    rm -f "$held/owner.pid" "$held/owner.token" "$held/process.json"
    rmdir "$held" 2>/dev/null || true
  fi
  lock_held=""
  lock_token=""
}

trap 'lock_release' EXIT

json_read() { jq -r "$2" "$1" 2>/dev/null || true; }

# Two attempts collide when they write to the same working tree, which is the
# git worktree root — not the cwd, since one may be launched from a subdirectory
# of the other. Outside a repo, the resolved directory is the best we can do.
worktree_key() {
  local dir="$1" top
  [ -d "$dir" ] || { printf '%s\n' "$dir"; return 0; }
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ]; then printf '%s\n' "$top"; else (cd "$dir" && pwd -P); fi
}

# tasks_awaiting_in_tree KEY — Tasks in this tree that finished and never got a
# decision. They sit in that state indefinitely; on this machine some have for
# weeks, in repos nobody was looking at.
tasks_awaiting_in_tree() {
  local key="$1" d id tcwd
  for d in "$state_root"/task_*/; do
    [ -f "$d/task.json" ] || continue
    [ "$(task_state "$d")" = "awaiting_supervisor" ] || continue
    tcwd="$(json_read "$d/task.json" '.cwd')"
    [ -n "$tcwd" ] || continue
    [ "$(worktree_key "$tcwd")" = "$key" ] || continue
    id="$(basename "$d")"
    printf '%s\n' "$id"
  done
}

# tasks_live_in_tree KEY [EXCLUDE_TASK_ID] — Tasks with a running attempt whose
# working tree is KEY. The cheap state check comes first: resolving a worktree
# for every Task on disk would cost one git call per historical Task.
tasks_live_in_tree() {
  local key="$1" exclude="${2:-}" d id tcwd
  for d in "$state_root"/task_*/; do
    [ -f "$d/task.json" ] || continue
    id="$(basename "$d")"
    [ "$id" != "$exclude" ] || continue
    [ "$(task_state "$d")" = "running" ] || continue
    attempt_running "$d" || continue
    tcwd="$(json_read "$d/task.json" '.cwd')"
    [ -n "$tcwd" ] || continue
    [ "$(worktree_key "$tcwd")" = "$key" ] || continue
    printf '%s\n' "$id"
  done
}

# ---------------------------------------------------------------------- events

# event_append TASKDIR TYPE [PAYLOAD_JSON]
event_append() {
  local dir="$1" type="$2" payload="${3:-{\}}" own=0 seq line
  if [ -z "$lock_held" ]; then lock_acquire "$dir"; own=1; fi
  [ "$lock_held" = "$dir/.lock" ] || { echo "BUG: event append without the matching Task lock" >&2; return 1; }
  seq="$(tail -n 1 "$dir/events.jsonl" 2>/dev/null | jq -r '.seq // 0' 2>/dev/null || echo 0)"
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  seq=$((seq + 1))
  line="$(jq -c -n \
    --argjson seq "$seq" \
    --arg ts "$(now_iso)" \
    --arg type "$type" \
    --argjson payload "$payload" \
    '$payload + {seq: $seq, ts: $ts, type: $type}')" || {
      if [ "$own" -eq 1 ]; then lock_release; fi
      return 1
    }
  # One compact line and one append write: concurrent appenders are serialized
  # by the Task lock, and a signal cannot strand jq's partially streamed output.
  printf '%s\n' "$line" >>"$dir/events.jsonl"
  if [ "$own" -eq 1 ]; then lock_release; fi
}

# ------------------------------------------------------------------- task state

task_exists() { [ -f "$state_root/$1/task.json" ]; }

# A directory left by the pre-Task job layout (or by the sibling claude/codex
# skills, which share this root). Readable, never reinterpreted as a Task.
legacy_job_exists() { [ -d "$state_root/$1" ] && [ ! -f "$state_root/$1/task.json" ] && [ -f "$state_root/$1/status" ]; }

# task_update TASKDIR JQ_FILTER [jq args...] — atomic read-modify-write.
# The caller must hold the lock for any read-decide-write sequence.
task_update() {
  local dir="$1"; shift
  local filter="$1"; shift
  jq "$@" --arg _now "$(now_iso)" "($filter) | .updated_at = \$_now" "$dir/task.json" \
    | write_atomic "$dir/task.json"
}

task_state() { json_read "$1/task.json" '.state'; }

task_is_terminal() {
  case "$(task_state "$1")" in
    accepted|rejected|cancelled|taken_over) return 0 ;;
    *) return 1 ;;
  esac
}

# task_create TASKDIR TASK_ID CWD MODEL TIMEOUT TITLE
task_create() {
  local dir="$1" id="$2" cwd="$3" model="$4" timeout="$5" title="$6"
  mkdir -p "$dir/attempts" "$dir/verifications"
  : >"$dir/events.jsonl"
  jq -n \
    --argjson schema "$schema_version" \
    --arg task_id "$id" \
    --arg created "$(now_iso)" \
    --arg cwd "$cwd" \
    --arg model "$model" \
    --arg agent "$agent_name" \
    --argjson timeout "$timeout" \
    --arg title "$title" \
    '{
      schema: $schema,
      task_id: $task_id,
      created_at: $created,
      updated_at: $created,
      title: $title,
      cwd: $cwd,
      agent: $agent,
      model: $model,
      timeout_seconds: $timeout,
      state: "created",
      current_attempt: null,
      attempt_count: 0,
      session_id: null,
      outcome: {
        transport: "not_started",
        worker: "pending",
        verification: "not_run",
        supervisor: "pending"
      },
      failure_class: null,
      recommended_action: "wait",
      verification_count: 0,
      last_verification: null,
      disposition: null
    }' | write_atomic "$dir/task.json"
  event_append "$dir" task_created \
    "$(jq -c -n --arg cwd "$cwd" --arg model "$model" --arg title "$title" \
      '{cwd: $cwd, model: $model, title: $title}')"
}

# ---------------------------------------------------------------- worker report
# The worker ends its turn with a fixed block. Parsing it here is what turns the
# worker's semantic result into state the supervisor can branch on without
# reading prose. The last block in the transcript wins.

# report_section FILE LABEL
report_section() {
  [ -f "$1" ] || return 0
  awk -v want="$2" '
    {
      line = $0
      if (match(line, /^[[:space:]]*[A-Z_]+:[[:space:]]*/)) {
        label = substr(line, RSTART, RLENGTH)
        gsub(/[[:space:]:]/, "", label)
        if (label == "STATUS" || label == "FILES_CHANGED" || label == "VERIFICATION" \
            || label == "CONCERNS" || label == "QUESTION") {
          cur = label
          if (cur == want) { buf = substr(line, RSTART + RLENGTH); found = 1 }
          next
        }
      }
      if (found && cur == want) { buf = (buf == "" ? line : buf "\n" line) }
    }
    END { if (found) print buf }
  ' "$1"
}

# parse_worker_report REPORT_FILE -> JSON {worker, files_changed, verification, concerns, question}
parse_worker_report() {
  local file="$1" raw status files verification concerns question status_count
  status_count="$(awk '/^[[:space:]]*STATUS:[[:space:]]*/ { n++ } END { print n + 0 }' "$file" 2>/dev/null || echo 0)"
  raw="$(report_section "$file" STATUS | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:lower:]' '[:upper:]')"
  if [ "$status_count" -ne 1 ]; then raw=""; fi
  case "$raw" in
    DONE_WITH_CONCERNS) status="done_with_concerns" ;;
    DONE)               status="done" ;;
    BLOCKED)            status="blocked" ;;
    *)                   status="no_report" ;;
  esac
  files="$(report_section "$file" FILES_CHANGED | sed -n 's/^[[:space:]]*-[[:space:]]*//p')"
  verification="$(report_section "$file" VERIFICATION)"
  concerns="$(report_section "$file" CONCERNS)"
  question="$(report_section "$file" QUESTION)"
  if [ "$status" = "blocked" ] && [ -z "$question" ]; then question="$concerns"; fi
  jq -n \
    --arg worker "$status" \
    --arg files "$files" \
    --arg verification "$verification" \
    --arg concerns "$concerns" \
    --arg question "$question" \
    '{
      worker: $worker,
      worker_files_changed: ($files | split("\n") | map(select(length > 0))),
      worker_verification: (if $verification == "" then null else $verification end),
      worker_concerns: (if $concerns == "" then null else $concerns end),
      worker_question: (if $question == "" then null else $question end)
    }'
}

# ------------------------------------------------------- failure classification
# One recommendation per failure shape. The supervisor is never obliged to
# follow it; nothing here performs recovery on its own.

# classify_attempt EXIT_CODE WORKER_STATUS SESSION_ID STDERR_FILE -> "class|action"
classify_attempt() {
  local code="$1" worker="$2" session="$3" errf="$4" err=""
  [ -f "$errf" ] && err="$(tail -c 4000 "$errf" 2>/dev/null || true)"
  case "$code" in
    0)
      case "$worker" in
        done|done_with_concerns) echo "none|verify" ;;
        blocked)                 echo "worker_blocked|supervisor_decision" ;;
        *)                       echo "no_final_report|resume_same_session" ;;
      esac
      ;;
    4)   echo "provider_turn_incomplete|resume_same_session" ;;
    124) echo "timeout|inspect_diff" ;;
    130) echo "cancelled|none" ;;
    127) echo "opencode_missing|repair_infrastructure" ;;
    *)
      if printf '%s' "$err" | grep -qiE 'unauthorized|authentication|api key|not logged in|\b40[13]\b'; then
        echo "authentication_error|repair_infrastructure"
      elif printf '%s' "$err" | grep -qiE 'rate limit|overloaded|\b(429|50[0234])\b'; then
        echo "provider_error|retry_new_session"
      elif [ -z "$session" ]; then
        echo "session_creation_failed|retry_new_session"
      elif [ "$worker" = "blocked" ]; then
        echo "worker_blocked|supervisor_decision"
      else
        echo "worker_failed|retry_new_session"
      fi
      ;;
  esac
}

# The pre-Task `state` vocabulary, kept so existing --json consumers still work.
legacy_state_for() {
  local transport="$1" worker="$2"
  case "$transport" in
    running)    echo running ;;
    timeout)    echo timeout ;;
    cancelled)  echo cancelled ;;
    incomplete) echo incomplete ;;
    finished)
      case "$worker" in
        done|done_with_concerns|blocked) echo completed ;;
        *) echo incomplete ;;
      esac
      ;;
    *) echo failed ;;
  esac
}

# The orchestration event that best describes how an attempt ended.
attempt_event_for() {
  local transport="$1" worker="$2"
  case "$transport" in
    timeout)    echo attempt_timeout ;;
    cancelled)  echo attempt_cancelled ;;
    incomplete) echo attempt_incomplete ;;
    finished)
      case "$worker" in
        blocked)                 echo worker_blocked ;;
        done|done_with_concerns) echo worker_done ;;
        *)                       echo attempt_incomplete ;;
      esac
      ;;
    *) echo attempt_failed ;;
  esac
}

# ------------------------------------------------------------------- attempts

attempt_dir() { echo "$1/attempts/$2"; }

attempt_id_for() { printf 'attempt_%03d' "$1"; }

attempt_pid() { cat "$1/pid" 2>/dev/null || true; }

attempt_provider_pid() { cat "$1/provider.pid" 2>/dev/null || true; }

attempt_alive() {
  local pid
  pid="$(attempt_pid "$1")"
  if [ -n "$pid" ]; then
    if [ -f "$1/process.json" ]; then
      process_identity_alive "$1/process.json" "$pid" && return 0
    elif kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  pid="$(attempt_provider_pid "$1")"
  [ -n "$pid" ] || return 1
  if [ -f "$1/provider-process.json" ]; then
    process_identity_alive "$1/provider-process.json" "$pid"
  else
    kill -0 "$pid" 2>/dev/null
  fi
}

# Signal both the detached supervisor runner and the provider command it owns.
# The latter has its own process group when setsid is available; the direct-PID
# fallback covers platforms without it.
attempt_signal() {
  local dir="$1" sig="$2" pid
  pid="$(attempt_pid "$dir")"
  if [ -n "$pid" ] && { [ ! -f "$dir/process.json" ] || process_identity_alive "$dir/process.json" "$pid"; }; then
    kill -"$sig" -- "-$pid" 2>/dev/null || kill -"$sig" "$pid" 2>/dev/null || true
  fi
  pid="$(attempt_provider_pid "$dir")"
  if [ -n "$pid" ] && { [ ! -f "$dir/provider-process.json" ] || process_identity_alive "$dir/provider-process.json" "$pid"; }; then
    kill -"$sig" -- "-$pid" 2>/dev/null || kill -"$sig" "$pid" 2>/dev/null || true
  fi
}

# Seconds since the newest row the provider actually recorded. The snapshot
# file's own mtime is not that: the poller rewrites it on a fixed interval, so
# its age measures the poller and never exceeds the poll interval.
provider_activity_seconds() {
  local f="$1" newest age
  [ -s "$f" ] || { echo null; return 0; }
  newest="$(jq -r '[.[].time_created? // empty] | max // empty' "$f" 2>/dev/null || true)"
  case "$newest" in
    ''|*[!0-9]*) echo null; return 0 ;;
  esac
  age=$(( $(now_epoch) - newest / 1000 ))
  [ "$age" -ge 0 ] || age=0
  echo "$age"
}

file_age_seconds() {
  local f="$1" mtime
  [ -e "$f" ] || { echo null; return 0; }
  mtime="$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")"
  if [ -z "$mtime" ]; then echo null; else echo $(( $(now_epoch) - mtime )); fi
}

# Liveness from telemetry we already collect: the provider progress snapshot and
# the CLI event stream. No heartbeat messages, no tokens spent to prove life.
attempt_liveness() {
  local dir="$1" started elapsed alive=false stall
  started="$(json_read "$dir/meta.json" '.started_epoch // 0')"
  elapsed=$(( $(now_epoch) - ${started:-0} ))
  attempt_alive "$dir" && alive=true
  stall="${stall_threshold:-300}"
  jq -n \
    --argjson alive "$alive" \
    --argjson elapsed "$elapsed" \
    --argjson provider "$(provider_activity_seconds "$dir/provider-progress.json")" \
    --argjson output "$(file_age_seconds "$dir/raw.jsonl")" \
    --argjson threshold "$stall" \
    '(
      [$provider, $output] | map(select(. != null)) | min
    ) as $idle | {
      process_alive: $alive,
      elapsed_seconds: $elapsed,
      last_provider_activity_seconds: $provider,
      last_output_seconds: $output,
      idle_seconds: $idle,
      stall_threshold_seconds: $threshold,
      possibly_stalled: (($idle != null) and ($idle > $threshold))
    }'
}

# attempt_create TASKDIR INDEX KIND RETRY_OF SESSION REASON REQUEST
# Writes meta.json and request.md, registers the attempt as authoritative.
attempt_create() {
  local task_dir="$1" index="$2" kind="$3" retry_of="$4" session="$5" reason="$6" request="$7"
  local id adir
  id="$(attempt_id_for "$index")"
  adir="$(attempt_dir "$task_dir" "$id")"
  mkdir -p "$adir"
  printf '%s\n' "$request" >"$adir/request.md"
  : >"$adir/raw.jsonl"
  : >"$adir/stderr.log"
  : >"$adir/worker-report.txt"
  : >"$adir/changed-files.txt"
  echo '[]' >"$adir/provider-progress.json"
  jq -n \
    --arg attempt_id "$id" \
    --arg task_id "$(basename "$task_dir")" \
    --arg kind "$kind" \
    --arg retry_of "$retry_of" \
    --argjson index "$index" \
    --arg created "$(now_iso)" \
    --argjson started_epoch "$(now_epoch)" \
    --arg model "$model" \
    --arg cwd "${cwd:-$PWD}" \
    --arg agent "$agent_name" \
    --argjson timeout "$hard_timeout" \
    --arg session "$session" \
    --arg reason "$reason" \
    '{
      attempt_id: $attempt_id,
      task_id: $task_id,
      index: $index,
      kind: $kind,
      retry_of: (if $retry_of == "" then null else $retry_of end),
      created_at: $created,
      started_at: $created,
      started_epoch: $started_epoch,
      model: $model,
      cwd: $cwd,
      agent: $agent,
      timeout_seconds: $timeout,
      requested_session: (if $session == "" then null else $session end),
      session_reused: ($session != ""),
      reason: (if $reason == "" then null else $reason end)
    }' | write_atomic "$adir/meta.json"
  echo "$adir"
}

# attempt_register TASKDIR ATTEMPT_ID — make it the authoritative attempt.
attempt_register() {
  local task_dir="$1" id="$2" own=0
  if [ -z "$lock_held" ]; then lock_acquire "$task_dir"; own=1; fi
  task_update "$task_dir" \
    '.current_attempt = $id
     | .attempt_count = (.attempt_count + 1)
     | .state = "running"
     | .outcome.transport = "running"
     | .outcome.worker = "pending"
     | .outcome.supervisor = "pending"
     | .outcome.verification = "not_run"
     | .failure_class = null
     | .recommended_action = "wait"' \
    --arg id "$id"
  event_append "$task_dir" attempt_started \
    "$(jq -c -n --arg attempt "$id" --slurpfile meta "$task_dir/attempts/$id/meta.json" \
      '{attempt: $attempt, kind: $meta[0].kind, retry_of: $meta[0].retry_of,
        requested_session: $meta[0].requested_session, model: $meta[0].model,
        reason: $meta[0].reason}')"
  if [ "$own" -eq 1 ]; then lock_release; fi
}

# attempt_finalize TASKDIR ATTEMPT_ID — fold a finished attempt into the Task.
# Returns 1 (and marks the attempt non-authoritative) if a newer attempt took
# over or the supervisor already closed the Task.
attempt_finalize() {
  local task_dir="$1" id="$2" own=0 current terminal=0 authoritative=true finalized
  local adir transport worker session cost event
  adir="$(attempt_dir "$task_dir" "$id")"
  if [ -z "$lock_held" ]; then lock_acquire "$task_dir"; own=1; fi

  finalized="$(json_read "$adir/result.json" '.authoritative')"
  if [ "$finalized" = "false" ] \
    || { [ "$finalized" = "true" ] \
      && { [ "$(task_state "$task_dir")" != "running" ] \
        || [ "$(json_read "$task_dir/task.json" '.current_attempt')" != "$id" ]; }; }; then
    if [ "$own" -eq 1 ]; then lock_release; fi
    return 0
  fi

  current="$(json_read "$task_dir/task.json" '.current_attempt')"
  task_is_terminal "$task_dir" && terminal=1
  if [ "$current" != "$id" ] || [ "$terminal" -eq 1 ]; then authoritative=false; fi

  transport="$(json_read "$adir/result.json" '.transport')"
  worker="$(json_read "$adir/result.json" '.worker')"
  session="$(json_read "$adir/result.json" '.session_id // ""')"
  cost="$(json_read "$adir/result.json" '.cost_usd')"

  if [ "$authoritative" != "true" ]; then
    if ! jq -e --arg attempt "$id" 'select(.type == "attempt_stale" and .attempt == $attempt)' \
      "$task_dir/events.jsonl" >/dev/null 2>&1; then
      event_append "$task_dir" attempt_stale \
        "$(jq -c -n --arg attempt "$id" --arg current "$current" --arg transport "$transport" \
          --arg worker "$worker" \
          '{attempt: $attempt, superseded_by: $current, transport: $transport, worker: $worker,
            note: "finished after the Task moved on; Task state left untouched"}')"
    fi
    jq '.authoritative = false' "$adir/result.json" | write_atomic "$adir/result.json"
    if [ "$own" -eq 1 ]; then lock_release; fi
    return 0
  fi

  task_update "$task_dir" \
    '.state = "awaiting_supervisor"
     | .outcome.transport = $transport
     | .outcome.worker = $worker
     | .outcome.supervisor = (if $worker == "blocked" then "decision_required" else "pending" end)
     | .failure_class = (if $class == "none" then null else $class end)
     | .recommended_action = $action
     | .session_id = (if $session == "" then .session_id else $session end)
     | .last_cost_usd = (($cost | tonumber?) // null)' \
    --arg transport "$transport" \
    --arg worker "$worker" \
    --arg class "$(json_read "$adir/result.json" '.failure_class // "none"')" \
    --arg action "$(json_read "$adir/result.json" '.recommended_action')" \
    --arg session "$session" \
    --arg cost "${cost:-}"

  event="$(attempt_event_for "$transport" "$worker")"
  if ! jq -e --arg attempt "$id" --arg type "$event" \
    'select(.type == $type and .attempt == $attempt)' "$task_dir/events.jsonl" >/dev/null 2>&1; then
    event_append "$task_dir" "$event" \
      "$(jq -c -n --arg attempt "$id" --slurpfile r "$adir/result.json" \
        '{attempt: $attempt, transport: $r[0].transport, worker: $r[0].worker,
          exit_code: $r[0].exit_code, session_id: $r[0].session_id,
          failure_class: $r[0].failure_class, recommended_action: $r[0].recommended_action,
          question: $r[0].worker_question, changed_files: ($r[0].changed_files | length)}')"
  fi
  jq '.authoritative = true' "$adir/result.json" | write_atomic "$adir/result.json"

  if [ "$own" -eq 1 ]; then lock_release; fi
  return 0
}

# ---------------------------------------------------------------- verifications

# verification_next_id TASKDIR
verification_next_id() {
  local n
  n="$(json_read "$1/task.json" '.verification_count // 0')"
  printf 'ver_%03d' $(( ${n:-0} + 1 ))
}

# --------------------------------------------------------------- reconciliation
# Crash recovery. Covers: the supervisor dying, the runner dying between writing
# result.json and folding it into the Task, and a reboot leaving a Task marked
# running with nothing behind it.

# reconcile_task TASKDIR -> prints one of: ok | finalized | interrupted | running
reconcile_task() {
  local task_dir="$1" state current adir a reconciled=0
  lock_acquire "$task_dir"
  # Finish any result whose runner crashed before recording whether it was the
  # authoritative Attempt. This also fences old Attempts after a retry.
  for a in "$task_dir"/attempts/attempt_*/; do
    [ -f "${a}result.json" ] || continue
    [ "$(json_read "${a}result.json" '.authoritative')" = "null" ] || continue
    current="$(basename "${a%/}")"
    if ! jq -e --arg attempt "$current" \
      'select(.type == "task_reconciled" and .attempt == $attempt)' \
      "$task_dir/events.jsonl" >/dev/null 2>&1; then
      event_append "$task_dir" task_reconciled \
        "$(jq -c -n --arg attempt "$current" '{attempt: $attempt, finding: "result_not_folded_in"}')"
    fi
    attempt_finalize "$task_dir" "$current" >/dev/null
    reconciled=1
  done
  state="$(task_state "$task_dir")"
  if [ "$state" != "running" ]; then
    lock_release
    if [ "$reconciled" -eq 1 ]; then echo finalized; else echo ok; fi
    return 0
  fi
  current="$(json_read "$task_dir/task.json" '.current_attempt')"
  if [ -z "$current" ] || [ "$current" = "null" ]; then lock_release; echo ok; return 0; fi
  adir="$(attempt_dir "$task_dir" "$current")"

  if [ -f "$adir/result.json" ]; then
    if ! jq -e --arg attempt "$current" \
      'select(.type == "task_reconciled" and .attempt == $attempt)' \
      "$task_dir/events.jsonl" >/dev/null 2>&1; then
      event_append "$task_dir" task_reconciled \
        "$(jq -c -n --arg attempt "$current" '{attempt: $attempt, finding: "result_not_folded_in"}')"
    fi
    attempt_finalize "$task_dir" "$current" >/dev/null
    lock_release
    echo finalized
    return 0
  fi

  if attempt_alive "$adir"; then lock_release; echo running; return 0; fi

  # No result and no process: the run was interrupted. Record what we have
  # rather than inventing an outcome for it.
  attempt_write_result "$adir" "" "" "" 1 failed interrupted inspect_diff
  event_append "$task_dir" task_reconciled \
    "$(jq -c -n --arg attempt "$current" '{attempt: $attempt, finding: "process_gone_without_result"}')"
  attempt_finalize "$task_dir" "$current" >/dev/null
  lock_release
  echo interrupted
}

# ------------------------------------------------------------------ result.json

# attempt_write_result ATTEMPT_DIR SESSION COST REPORT_TEXT EXIT TRANSPORT CLASS ACTION
# The worker's semantic result is parsed here, not by the supervising model.
attempt_write_result() {
  local adir="$1" session="$2" cost="$3" report="$4" code="$5" transport="$6" class="$7" action="$8"
  local parsed started
  # A crash can leave an attempt directory half-built; reconciliation still has
  # to be able to write a result for it.
  [ -f "$adir/worker-report.txt" ] || : >"$adir/worker-report.txt"
  [ -f "$adir/changed-files.txt" ] || : >"$adir/changed-files.txt"
  if [ -n "$report" ]; then printf '%s\n' "$report" >"$adir/worker-report.txt"; fi
  parsed="$(parse_worker_report "$adir/worker-report.txt")"
  # Only a finished turn can carry a trustworthy semantic result. An incomplete
  # provider turn may contain a mid-turn "STATUS: DONE" that means nothing yet.
  case "$transport" in
    finished)   ;;
    incomplete) parsed="$(printf '%s' "$parsed" | jq -c '.worker = "no_report"')" ;;
    *)          parsed="$(printf '%s' "$parsed" | jq -c '.worker = "failed"')" ;;
  esac
  started="$(json_read "$adir/meta.json" '.started_epoch // 0')"
  jq -n \
    --argjson parsed "$parsed" \
    --arg session "$session" \
    --arg cost "$cost" \
    --argjson code "$code" \
    --arg transport "$transport" \
    --arg class "$class" \
    --arg action "$action" \
    --arg ended "$(now_iso)" \
    --argjson elapsed "$(( $(now_epoch) - ${started:-0} ))" \
    --rawfile report "$adir/worker-report.txt" \
    --rawfile changed "$adir/changed-files.txt" \
    'def normalize_reported_path:
         gsub("`"; "")
       | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
       | sub("^\\./"; "")
       | sub("[[:space:]]*\\(.*$"; "")
       | sub("[[:space:]]+[-\u2014\u2013][[:space:]].*$"; "")
       | sub("[[:space:]]+$"; "");
     def is_pathlike: (length > 0) and ((test("[[:space:]]")) | not);
     $parsed + {
      transport: $transport,
      exit_code: $code,
      session_id: (if $session == "" then null else $session end),
      cost_usd: (($cost | tonumber?) // null),
      ended_at: $ended,
      elapsed_seconds: $elapsed,
      failure_class: (if $class == "none" then null else $class end),
      recommended_action: $action,
      report: $report,
      changed_files: ($changed | split("\n") | map(select(length > 0))),
      authoritative: null
    }
    # The tree diff is the objective record and keeps its meaning. Crossing it
    # with what the worker said it touched only splits it into two views: what
    # this attempt claims, and what it did not account for — a second worker in
    # the same tree, or a file the worker forgot to list.
    | (.worker_files_changed | map(normalize_reported_path) | map(select(is_pathlike))) as $claimed
    | .worker_attributed_files = (.changed_files | map(select(. as $f | $claimed | index($f))))
    | .unattributed_files = (.changed_files - .worker_attributed_files)
    ' | write_atomic "$adir/result.json"
}

# ------------------------------------------------------------------- rendering

# json_attempt ATTEMPT_DIR — meta merged with the result, or with live liveness.
json_attempt() {
  local adir="$1"
  if [ -f "$adir/result.json" ]; then
    jq -s '.[0] * .[1] + {attempt_dir: $dir}' --arg dir "$adir" \
      "$adir/meta.json" "$adir/result.json"
  else
    jq -s '.[0] + {transport: "running", worker: "pending", exit_code: null,
                   liveness: .[1], attempt_dir: $dir}' --arg dir "$adir" \
      "$adir/meta.json" <(attempt_liveness "$adir")
  fi
}

# json_task TASKDIR [--full]
json_task() {
  local dir="$1" full="${2:-}" attempts="[]" verifications="[]" events="[]" current adir live="null"
  current="$(json_read "$dir/task.json" '.current_attempt')"
  if [ -n "$current" ] && [ "$current" != "null" ]; then
    adir="$(attempt_dir "$dir" "$current")"
    [ -d "$adir" ] && [ ! -f "$adir/result.json" ] && live="$(attempt_liveness "$adir")"
  fi
  if [ "$full" = "--full" ]; then
    attempts="$(for a in "$dir"/attempts/attempt_*/; do [ -d "$a" ] && json_attempt "${a%/}"; done | jq -s '.')"
    if compgen -G "$dir/verifications/ver_*.json" >/dev/null; then
      verifications="$(jq -s '.' "$dir"/verifications/ver_*.json)"
    fi
    if [ -s "$dir/events.jsonl" ]; then events="$(jq -s '.' "$dir/events.jsonl")"; fi
  fi
  jq \
    --argjson attempts "$attempts" \
    --argjson verifications "$verifications" \
    --argjson events "$events" \
    --argjson liveness "$live" \
    --arg state_dir "$dir" \
    --argjson full "$([ "$full" = "--full" ] && echo true || echo false)" \
    '. + {
      job_id: .task_id,
      state_dir: $state_dir,
      liveness: $liveness
    } + (if $full then {attempts: $attempts, verifications: $verifications, events: $events} else {} end)' \
    "$dir/task.json"
}

# json_status TASKDIR — the flat, per-attempt view the pre-Task --json emitted,
# widened with the Task/Attempt/verification dimensions.
json_status() {
  local dir="$1" current adir attempt="null"
  current="$(json_read "$dir/task.json" '.current_attempt')"
  if [ -n "$current" ] && [ "$current" != "null" ]; then
    adir="$(attempt_dir "$dir" "$current")"
    [ -d "$adir" ] && attempt="$(json_attempt "$adir")"
  fi
  jq \
    --argjson attempt "$attempt" \
    --arg state_dir "$dir" \
    '{
      task_id: .task_id,
      job_id: .task_id,
      task_state: .state,
      title: .title,
      attempt_id: .current_attempt,
      attempt_count: .attempt_count,
      outcome: .outcome,
      failure_class: .failure_class,
      recommended_action: .recommended_action,
      session_id: .session_id,
      model: .model,
      agent: .agent,
      cwd: .cwd,
      state_dir: $state_dir,
      verification_count: .verification_count,
      last_verification: .last_verification,
      disposition: .disposition,
      attempt: $attempt
    }
    | .exit_code = ($attempt.exit_code // null)
    | .cost_usd = ($attempt.cost_usd // null)
    | .elapsed_seconds = ($attempt.elapsed_seconds // $attempt.liveness.elapsed_seconds // 0)
    | .liveness = ($attempt.liveness // null)
    | .report = (if ($attempt.transport // "running") == "running" then null else ($attempt.report // null) end)
    | .changed_files = ($attempt.changed_files // [])
    | .worker_attributed_files = ($attempt.worker_attributed_files // [])
    | .unattributed_files = ($attempt.unattributed_files // [])
    | .state = (if ($attempt.transport // "running") == "running" then "running"
                else $legacy end)' \
    --arg legacy "$(legacy_state_for \
      "$(json_read "$dir/attempts/$current/result.json" '.transport' 2>/dev/null)" \
      "$(json_read "$dir/attempts/$current/result.json" '.worker' 2>/dev/null)")" \
    "$dir/task.json"
}

# render_status TASKDIR — human output. Keeps the SESSION/COST/EXIT/--- REPORT ---
# shape the pre-Task versions printed, so existing eyeballs and greps still work.
# The worker's structured block is parsed into result.json already, so render
# those fields rather than tailing the raw text: a long CONCERNS list would
# otherwise push QUESTION out of the tail, and a fallback report is not the
# block at all but raw provider JSONL.
render_status() {
  json_status "$1" | jq -r --argjson full "${report_full:-0}" '
    def report_view:
      if $full == 1 then (.report // "(no worker report)")
      elif (.attempt.worker_question // null) != null or (.attempt.worker_verification // null) != null
           or (.attempt.worker_concerns // null) != null then
        ([ (if (.attempt.worker_verification // null) != null then "VERIFICATION: " + .attempt.worker_verification else empty end),
           (if (.attempt.worker_question // null) != null then "QUESTION: " + .attempt.worker_question else empty end),
           (if (.attempt.worker_concerns // null) != null then "CONCERNS: " + .attempt.worker_concerns else empty end)
         ] | join("\n"))
        + "\n(full report: logs TASK --stream report)"
      else
        # Two caps: a fallback report is raw provider JSONL, where a handful of
        # lines can still be tens of kilobytes.
        ((.report // "(no worker report)") | split("\n")) as $lines
        | (if ($lines | length) <= 20 then ($lines | join("\n"))
           else "… (\(($lines | length) - 20) earlier lines elided; --full or logs TASK --stream report)\n"
                + ($lines[-20:] | join("\n")) end) as $view
        | if ($view | length) > 2000
          then "… (truncated to the last 2000 characters; --full or logs TASK --stream report)\n"
               + ($view[-2000:])
          else $view end
      end;

    "TASK: \(.task_id)",
    "TITLE: \(.title // "-")",
    "ATTEMPT: \(.attempt_id // "-") (\(.attempt.kind // "-")\(if .attempt.retry_of then ", retry of \(.attempt.retry_of)" else "" end))",
    "SESSION: \(.session_id // "unknown")",
    "MODEL: \(.model // "unknown")",
    "COST: \(.cost_usd // "unknown")",
    "EXIT: \(.exit_code // "unknown")",
    "TRANSPORT: \(.outcome.transport)",
    "WORKER: \(.outcome.worker)",
    "VERIFICATION: \(.outcome.verification)",
    "SUPERVISOR: \(.outcome.supervisor)",
    (if .failure_class then "FAILURE: \(.failure_class)" else empty end),
    "NEXT: \(.recommended_action)",
    (if (.changed_files // []) | length > 0 then
       "FILES: \((.worker_attributed_files // []) | join(", "))"
       + (if (.unattributed_files // []) | length > 0
          then " | unattributed: \((.unattributed_files) | join(", "))" else "" end)
     else empty end),
    "--- REPORT ---",
    report_view'
}
