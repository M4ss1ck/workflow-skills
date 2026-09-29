#!/usr/bin/env bash
# Validate the subagent delegate scripts against stubbed CLIs (no real API calls).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

fail() {
  echo "FAIL  $1" >&2
  exit 1
}

# jq must be real; the stubs replace only the provider CLIs.
command -v jq >/dev/null || fail "these tests require jq on PATH"

# Sandbox job state and conf under the temp dir; poll fast so tests stay quick.
run_delegate() {
  local script="$1"
  shift
  STUB_DIR="$stub_dir" \
  STUB_SLEEP="${STUB_SLEEP:-0}" \
  STUB_RESUME_HANG="${STUB_RESUME_HANG:-0}" \
  STUB_FRESH_HANG="${STUB_FRESH_HANG:-0}" \
  STUB_NO_FINAL="${STUB_NO_FINAL:-0}" \
  STUB_EXPORT_FAIL="${STUB_EXPORT_FAIL:-0}" \
  STUB_STREAM_ERROR="${STUB_STREAM_ERROR:-}" \
  STUB_VERSION="${STUB_VERSION:-2.0.16}" \
  STUB_SILENT_SLEEP="${STUB_SILENT_SLEEP:-0}" \
  STUB_SESSION="${STUB_SESSION:-ses_oc1}" \
  STUB_STEPS="${STUB_STEPS:-1}" \
  STUB_FILES="${STUB_FILES:-- foo.txt}" \
  STUB_FINISH_DRIFT="${STUB_FINISH_DRIFT:-0}" \
  STUB_LATE_FINAL="${STUB_LATE_FINAL:-0}" \
  STUB_STATUS="${STUB_STATUS:-DONE}" \
  XDG_STATE_HOME="$stub_dir/state" \
  XDG_CONFIG_HOME="$stub_dir/config" \
  DELEGATE_POLL_INTERVAL=1 \
  PATH="$stub_dir:$PATH" bash "$script" "$@"
}

job_of() { echo "$1" | sed -n 's/^JOB: //p'; }
jobdir_of() { echo "$stub_dir/state/workflow-skills/subagents/$1"; }
# opencode-subagent is Task-oriented; pre-Task state still uses the older JOB line.
task_of() { echo "$1" | sed -n 's/^TASK: //p'; }
taskdir_of() { echo "$stub_dir/state/workflow-skills/subagents/$1"; }
conf_file="$stub_dir/config/workflow-skills/subagents.conf"

# Launch, then wait to completion; prints the wait output.
launch_and_wait() {
  local script="$1"
  shift
  local out id
  out="$(run_delegate "$script" "$@")"
  id="$(job_of "$out")"
  [ -n "$id" ] || id="$(task_of "$out")"
  run_delegate "$script" --wait "$id" --poll-timeout 30
}

# --- stub: opencode ---------------------------------------------------------
# Mimics OpenCode 2.x: `--version`, `run --standalone --format json` whose
# stream has no step_finish after the closing text, and `session export`, fed
# from a per-session message store the stub run appends to.
cat >"$stub_dir/opencode" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "opencode v${STUB_VERSION:-2.0.16}"
  exit 0
fi
store_of() { printf '%s/sessions/%s.jsonl' "$STUB_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_')"; }

if [ "${1:-}" = "session" ] && [ "${2:-}" = "export" ]; then
  shift 2
  [ "${1:-}" != "--standalone" ] || shift
  printf '%s\n' "$1" >>"${STUB_DIR}/opencode-export.args"
  if [ "${STUB_EXPORT_FAIL:-0}" = "1" ]; then
    echo 'stub export failure' >&2
    exit 1
  fi
  store="$(store_of "$1")"
  jq -n --arg id "$1" --slurpfile m "$( [ -f "$store" ] && echo "$store" || echo /dev/null)" \
    '{info: {id: $id}, messages: $m}'
  exit 0
fi

if [ "${1:-}" = "session" ] && [ "${2:-}" = "list" ]; then
  if [ -f "${STUB_DIR}/sessions/index.jsonl" ]; then jq -s 'reverse' "${STUB_DIR}/sessions/index.jsonl"; else echo '[]'; fi
  exit 0
fi

printf '%s\n' "$*" >>"${STUB_DIR}/opencode.args"
printf '%s\n' "$PWD" >>"${STUB_DIR}/opencode.pwd"

# The worker's real contract is the STATUS/FILES_CHANGED/VERIFICATION/CONCERNS
# block; STUB_STATUS picks which semantic outcome this turn reports.
worker_report() {
  printf 'STATUS: %s\n' "${STUB_STATUS:-DONE}"
  printf 'FILES_CHANGED:\n%s\n' "${STUB_FILES:-- foo.txt}"
  printf 'VERIFICATION:\nstub check -> pass\n'
  if [ "${STUB_STATUS:-DONE}" = "BLOCKED" ]; then
    printf 'QUESTION:\nShould the cache be write-through or write-back?\n'
  fi
  printf 'CONCERNS:\n- none\n'
}

session="${STUB_SESSION:-ses_oc1}"
title=""
prev=""
for a in "$@"; do
  [ "$prev" != "--session" ] || session="$a"
  [ "$prev" != "--title" ] || title="$a"
  prev="$a"
done
mkdir -p "${STUB_DIR}/sessions"
[ -z "$title" ] || jq -c -n --arg id "$session" --arg t "$title" '{id: $id, title: $t}' >>"${STUB_DIR}/sessions/index.jsonl"
store="$(store_of "$session")"
# a session created by this run starts empty
[[ " $* " == *" --session "* ]] || : >"$store"
turn="$$-$RANDOM"
last_arg="${!#}"
# fixed, old provider timestamps: liveness must come from real activity, not these
msg() {
  jq -c -n --arg id "msg_${turn}_$1" --arg type "$2" --arg finish "${3:-}" --arg text "${4:-}" --arg tool "${5:-}" \
    --argjson cost "${6:-null}" \
    '{id: $id, type: $type, time: {created: 2000, completed: 2000}}
     + (if $type == "user" then {text: $text} else {} end)
     + (if $type == "assistant" then
          {finish: (if $finish == "" then null else $finish end), cost: $cost,
           content: ((if $text == "" then [] else [{type: "text", text: $text}] end)
                     + (if $tool == "" then [] else [{type: "tool", name: $tool, state: {status: "completed"}}] end))}
        else {} end)' >>"$store"
}
event() {
  jq -c -n --arg type "$1" --arg s "$session" --argjson part "$2" '{type: $type, timestamp: 1, sessionID: $s, part: $part}'
}

msg u user "" "$last_arg"
echo "stub banner noise (must stay out of raw.jsonl)" >&2
if [ -n "${STUB_STREAM_ERROR:-}" ]; then
  jq -c -n --arg s "$session" --arg m "$STUB_STREAM_ERROR" '{type: "error", timestamp: 1, sessionID: $s, error: {type: "unknown", message: $m}}'
  exit 1
fi
case "$*" in *touch-artifact*) : >"$PWD/worker-artifact.txt" ;; esac
case "$*" in *touch-two*) : >"$PWD/worker-artifact.txt"; : >"$PWD/other-artifact.txt" ;; esac
# 2.x says nothing on the stream until the model starts answering
sleep "${STUB_SILENT_SLEEP:-0}"
event step_start '{"type":"step-start"}'
if { [ "${STUB_RESUME_HANG:-0}" = "1" ] && [[ " $* " == *" --session "* ]]; } \
  || { [ "${STUB_FRESH_HANG:-0}" = "1" ] && [[ " $* " != *" --session "* ]]; }; then
  msg a assistant stop "$(worker_report)" "" 0.0042
  msg i idle
  sleep 30
  exit 0
fi
sleep "${STUB_SLEEP:-0}"
# A multi-step turn: one tool step per extra step, each with its own
# step_finish and cost; the closing text step has no step_finish.
i=1
while [ "$i" -lt "${STUB_STEPS:-1}" ]; do
  event tool_use '{"type":"tool","tool":"glob","state":{"status":"completed"}}'
  event step_finish '{"type":"step-finish","reason":"tool-calls","cost":0.0042}'
  msg "t$i" assistant tool-calls "" glob 0.0042
  event step_start '{"type":"step-start"}'
  i=$((i + 1))
done
if [ "${STUB_NO_FINAL:-0}" = "1" ]; then
  # the turn stopped after a tool call, with nothing after it
  event tool_use '{"type":"tool","tool":"glob","state":{"status":"completed"}}'
  msg a assistant tool-calls "" glob 0.0042
  exit 0
fi
if [ "${STUB_LATE_FINAL:-0}" = "1" ]; then
  event text '{"type":"text","text":"Still working."}'
  (
    sleep 3
    event step_start '{"type":"step-start"}'
    event text "$(jq -c -n --arg t "$(worker_report)" '{type: "text", text: $t}')"
    msg a assistant stop "$(worker_report)" "" 0.0042
    msg i idle
  ) &
  exit 0
fi
event text "$(jq -c -n --arg t "$(worker_report)" '{type: "text", text: $t}')"
if [ "${STUB_FINISH_DRIFT:-0}" = "1" ]; then
  msg a assistant end_turn "$(worker_report)" "" 0.0042
else
  msg a assistant stop "$(worker_report)" "" 0.0042
fi
msg i idle
exit 0
STUB
chmod +x "$stub_dir/opencode"

oc="$repo_root/skills/opencode-subagent/scripts/delegate.sh"
oc_agent="$stub_dir/config/opencode/agent/workflow-worker.md"

# --- invocation through a symlink -------------------------------------------

# the script is reached as ~/.local/bin/opencode-delegate and through symlinked
# skills directories, so it must resolve its own path, not the link's
link_dir="$stub_dir/link-bin"
mkdir -p "$link_dir"
ln -sf "$oc" "$link_dir/opencode-delegate"
out="$(run_delegate "$link_dir/opencode-delegate" policy 2>&1)" \
  || fail "opencode: invocation through a symlink failed: $out"
echo "$out" | grep -q '^DELEGATION_POLICY:' || fail "opencode: symlinked invocation lost its skill dir: $out"

# the usage block must not silently truncate as the header grows
out="$(run_delegate "$oc" --help)"
echo "$out" | grep -q 'Legacy forms still accepted' || fail "opencode: --help truncates the header: $out"

# --- attempt cost -----------------------------------------------------------

# step_finish carries that step's own cost, not a running total: reporting the
# last one under-reports every multi-step turn
mkdir -p "$(dirname "$conf_file")"
echo 'OPENCODE_SUBAGENT_MODEL=stub/conf-model' >"$conf_file"
out="$(STUB_STEPS=3 run_delegate "$oc" run --json "cost task")"
echo "$out" | jq -e '(.cost_usd * 10000 | round) == 126' >/dev/null \
  || fail "opencode: attempt cost is not the sum of its steps: $(echo "$out" | jq -c '{cost_usd}')"
# close it: later tests resolve a Task by session id, which needs one open owner
run_delegate "$oc" decide "$(echo "$out" | jq -r .task_id)" accept --reason "cost fixture" >/dev/null
rm -f "$conf_file"

# --- delegation policy ------------------------------------------------------

# an unconfigured conf is conservative, not permissive
out="$(run_delegate "$oc" policy)"
echo "$out" | grep -q '^DELEGATION_POLICY: explicit$' || fail "opencode: default policy is not explicit: $out"
echo "$out" | grep -q '^WORKER_MODEL: none$' || fail "opencode: unset worker model not reported: $out"

# retention is configurable and surfaced, not a hard-coded 7-day wipe
echo "$out" | grep -q '^RETENTION_DAYS: 90$' || fail "opencode: default retention not reported: $out"
echo "$out" | grep -q '^RAW_RETENTION_DAYS: 7$' || fail "opencode: raw retention not reported: $out"
run_delegate "$oc" policy --json | jq -e '.retention_days == 90 and .raw_retention_days == 7' >/dev/null \
  || fail "opencode: retention missing from policy --json"

# the policy is settable and readable as JSON
run_delegate "$oc" policy auto >/dev/null
run_delegate "$oc" policy --json | jq -e '.delegation_policy == "auto"' >/dev/null \
  || fail "opencode: policy auto not persisted"

# policy=off refuses to launch at all
run_delegate "$oc" policy off >/dev/null
set +e
msg="$(run_delegate "$oc" --model x/y "task" 2>&1)"
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: policy off should exit 2, got $code"
echo "$msg" | grep -q 'delegation is disabled' || fail "opencode: policy off lacks actionable error: $msg"

# an invalid policy is a config error, not a silent default
echo 'OPENCODE_SUBAGENT_DELEGATION_POLICY=sometimes' >"$conf_file"
set +e
run_delegate "$oc" --model x/y "task" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: invalid policy should exit 2, got $code"

# policy=explicit permits launching
run_delegate "$oc" policy explicit >/dev/null

# --- worker model resolution ------------------------------------------------

# with no --model and no configured worker model the launch fails loudly:
# inheriting OpenCode's global default would defeat the point of the skill
set +e
msg="$(run_delegate "$oc" "task" 2>&1)"
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: missing worker model should exit 2, got $code"
echo "$msg" | grep -q 'no worker model' || fail "opencode: missing-model error unclear: $msg"

# from here on a worker model is configured, so launches need not name one
mkdir -p "$(dirname "$conf_file")"
echo 'OPENCODE_SUBAGENT_MODEL=stub/conf-model' >"$conf_file"

# retention never removes unresolved Tasks or unrelated legacy job state
ret_active="$(taskdir_of task_retention_active)"
ret_done="$(taskdir_of task_retention_done)"
ret_sibling="$(jobdir_of legacy-retention-sibling)"
mkdir -p "$ret_active/attempts/attempt_001" "$ret_done/attempts/attempt_001" "$ret_sibling"
printf '{"state":"running"}\n' >"$ret_active/task.json"
printf '{"state":"accepted"}\n' >"$ret_done/task.json"
: >"$ret_active/attempts/attempt_001/raw.jsonl"
: >"$ret_done/attempts/attempt_001/raw.jsonl"
: >"$ret_sibling/status"
touch -d '3 days ago' "$ret_active/task.json" "$ret_active/attempts/attempt_001/raw.jsonl" \
  "$ret_done/task.json" "$ret_done/attempts/attempt_001/raw.jsonl" "$ret_sibling"
printf 'OPENCODE_SUBAGENT_RETENTION_DAYS=0\nOPENCODE_SUBAGENT_RAW_RETENTION_DAYS=0\n' >>"$conf_file"
ret_out="$(run_delegate "$oc" start "retention trigger")"
ret_task="$(task_of "$ret_out")"
[ -f "$ret_active/task.json" ] && [ -f "$ret_active/attempts/attempt_001/raw.jsonl" ] \
  || fail "opencode: retention pruned unresolved Task evidence"
[ ! -e "$ret_done" ] || fail "opencode: retention did not prune an old terminal Task"
[ -e "$ret_sibling/status" ] || fail "opencode: retention touched unrelated legacy job state"
run_delegate "$oc" wait "$ret_task" --poll-timeout 30 >/dev/null
run_delegate "$oc" decide "$ret_task" accept --reason "retention fixture complete" >/dev/null
rm -rf "$ret_active" "$ret_sibling"
# Restore defaults for the remaining tests.
grep -v '^OPENCODE_SUBAGENT_.*RETENTION_DAYS=' "$conf_file" >"$conf_file.tmp"
mv "$conf_file.tmp" "$conf_file"

# --- Task and Attempt creation ----------------------------------------------

# launch returns immediately and names both the Task and its first Attempt
out="$(run_delegate "$oc" --model anthropic/claude-haiku-4-5 "do the thing")"
echo "$out" | grep -q '^TASK: task_' || fail "opencode: no TASK line: $out"
echo "$out" | grep -q '^JOB: task_' || fail "opencode: legacy JOB alias missing: $out"
echo "$out" | grep -q '^ATTEMPT: attempt_001$' || fail "opencode: no ATTEMPT line: $out"
echo "$out" | grep -q '^WATCH:' || fail "opencode: no WATCH line: $out"
echo "$out" | grep -q '^STATUS:' || fail "opencode: legacy STATUS guidance missing: $out"
echo "$out" | grep -q '^PROGRESS:' || fail "opencode: no PROGRESS line: $out"
echo "$out" | grep -q '^REPORT:' || fail "opencode: no REPORT line: $out"
echo "$out" | grep -q '^PROVIDER_REPORT:' || fail "opencode: legacy PROVIDER_REPORT alias missing: $out"
echo "$out" | grep -q '^RESULT:' || fail "opencode: legacy RESULT alias missing: $out"
task="$(task_of "$out")"
td="$(taskdir_of "$task")"

# the exact request is persisted verbatim, not left only in the OpenCode session
[ -f "$td/attempts/attempt_001/request.md" ] || fail "opencode: attempt request not persisted"
grep -qx 'do the thing' "$td/attempts/attempt_001/request.md" \
  || fail "opencode: persisted request does not match what was sent"

# the Task is created with its own durable state and an append-only history
jq -e '.task_id == "'"$task"'" and .attempt_count == 1 and .current_attempt == "attempt_001"' \
  "$td/task.json" >/dev/null || fail "opencode: task.json wrong: $(cat "$td/task.json")"
jq -e '.opencode_version == "2.0.16"' "$td/attempts/attempt_001/meta.json" >/dev/null \
  || fail "opencode: exact CLI version was not persisted with the attempt"
jq -e '.type == "task_created" and .seq == 1' <(head -1 "$td/events.jsonl") >/dev/null \
  || fail "opencode: first event is not task_created"
jq -e 'select(.type == "attempt_started") | .opencode_version == "2.0.16"' "$td/events.jsonl" >/dev/null \
  || fail "opencode: attempt_started event omitted the exact CLI version"

# the dedicated worker agent is installed where opencode can resolve it
[ -f "$oc_agent" ] || fail "opencode: worker agent not synced to $oc_agent"
grep -q '^name: workflow-worker$' "$oc_agent" || fail "opencode: synced agent is not workflow-worker"

# --- successful worker completion -------------------------------------------

res="$(run_delegate "$oc" --wait "$task" --poll-timeout 30)"
grep -qE 'run --standalone --format json --agent workflow-worker --model anthropic/claude-haiku-4-5 --title workflow-worker task_[0-9-]+/attempt_001 do the thing' "$stub_dir/opencode.args" \
  || fail "opencode: unexpected args: $(cat "$stub_dir/opencode.args")"
echo "$res" | grep -q '^SESSION: ses_oc1$' || fail "opencode: session not extracted: $res"
echo "$res" | grep -q '^COST: 0.0042$' || fail "opencode: cost not extracted: $res"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: exit line missing: $res"
echo "$res" | grep -q -- '--- REPORT ---' || fail "opencode: report marker missing: $res"

# the worker's semantic outcome is promoted into state, not left as prose
echo "$res" | grep -q '^WORKER: done$' || fail "opencode: worker outcome not machine-readable: $res"
echo "$res" | grep -q '^TRANSPORT: finished$' || fail "opencode: transport outcome missing: $res"
echo "$res" | grep -q '^VERIFICATION: not_run$' || fail "opencode: verification dimension missing: $res"
echo "$res" | grep -q '^SUPERVISOR: pending$' || fail "opencode: supervisor dimension missing: $res"
jq -e '.worker == "done" and .worker_files_changed == ["foo.txt"]' \
  "$td/attempts/attempt_001/result.json" >/dev/null \
  || fail "opencode: worker report not parsed into result.json"
grep -q '"type":"worker_done"' "$td/events.jsonl" || fail "opencode: no worker_done event"
[ -f "$td/attempts/attempt_001/process.json" ] \
  || fail "opencode: process fingerprint was not persisted"
jq -e '.pid > 0 and .boot_id != null and .start_time != null' "$td/attempts/attempt_001/process.json" >/dev/null \
  || fail "opencode: process fingerprint is incomplete"
[ -f "$td/attempts/attempt_001/provider-process.json" ] \
  || fail "opencode: provider process fingerprint was not persisted"

# malformed, missing, or ambiguous STATUS blocks are never promoted to success
printf 'STATUS: DONE later\n' >"$stub_dir/bad-report.txt"
bad="$(STUB_DIR="$stub_dir" bash -c '
  state_root=/dev/null; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  parse_worker_report "'"$stub_dir"'/bad-report.txt"
')"
echo "$bad" | jq -e '.worker == "no_report"' >/dev/null \
  || fail "opencode: malformed STATUS was trusted: $bad"
printf 'STATUS: DONE\nSTATUS: BLOCKED\nQUESTION:\nWhich one?\n' >"$stub_dir/bad-report.txt"
bad="$(STUB_DIR="$stub_dir" bash -c '
  state_root=/dev/null; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  parse_worker_report "'"$stub_dir"'/bad-report.txt"
')"
echo "$bad" | jq -e '.worker == "no_report"' >/dev/null \
  || fail "opencode: multiple STATUS values were trusted: $bad"
printf 'STATUS: DONE\nFILES_CHANGED:\n- old.txt\nSTATUS: DONE\nFILES_CHANGED:\n- final.txt\nVERIFICATION:\npass\nCONCERNS:\n- none\n' >"$stub_dir/bad-report.txt"
bad="$(STUB_DIR="$stub_dir" bash -c '
  state_root=/dev/null; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  parse_worker_report "'"$stub_dir"'/bad-report.txt"
')"
echo "$bad" | jq -e '.worker == "done" and .worker_files_changed == ["final.txt"]' >/dev/null \
  || fail "opencode: repeated identical STATUS blocks did not use the last report: $bad"
printf '```text\nSTATUS: DONE\nFILES_CHANGED:\n- none\nVERIFICATION:\nnot needed\nQUESTION:\n- none\nCONCERNS:\n- none\n```\n' >"$stub_dir/bad-report.txt"
bad="$(STUB_DIR="$stub_dir" bash -c '
  state_root=/dev/null; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  parse_worker_report "'"$stub_dir"'/bad-report.txt"
')"
echo "$bad" | jq -e '.worker == "done" and .worker_files_changed == [] and .worker_concerns == null and .worker_question == null' >/dev/null \
  || fail "opencode: fenced report polluted parsed fields: $bad"

# a DONE worker is not an accepted task
jq -e '.state == "awaiting_supervisor" and .outcome.supervisor == "pending"' "$td/task.json" >/dev/null \
  || fail "opencode: worker DONE wrongly closed the task"
jq -e '.recommended_action == "verify"' "$td/task.json" >/dev/null \
  || fail "opencode: a finished worker should recommend verification"

# stderr is kept out of the JSON stream
ad="$td/attempts/attempt_001"
grep -q 'banner noise' "$ad/stderr.log" || fail "opencode: stderr.log missing stub noise"
jq -s empty "$ad/raw.jsonl" || fail "opencode: raw.jsonl contaminated (not clean JSONL)"
grep -q 'STATUS: DONE' "$ad/worker-report.txt" || fail "opencode: worker report file missing final response"

# --- independent verification -----------------------------------------------

# a failing verification is recorded, fails loudly, and does not touch the worker
set +e
res="$(run_delegate "$oc" verify "$task" --label acceptance -- sh -c 'echo boom; exit 3')"
code=$?
set -e
[ "$code" -eq 1 ] || fail "opencode: failed verification should exit 1, got $code"
echo "$res" | grep -q '^VERIFICATION: ver_001 failed (exit 3)$' || fail "opencode: verification result wrong: $res"
jq -e '.result == "failed" and .exit_code == 3 and .label == "acceptance"' "$td/verifications/ver_001.json" >/dev/null \
  || fail "opencode: verification record wrong: $(cat "$td/verifications/ver_001.json")"
jq -e '.command | test("echo boom")' "$td/verifications/ver_001.json" >/dev/null \
  || fail "opencode: verification command not persisted"
jq -e '.cwd != null and .started_at != null and .ended_at != null' "$td/verifications/ver_001.json" >/dev/null \
  || fail "opencode: verification record missing cwd/timestamps"
grep -q 'boom' "$td/verifications/ver_001.stdout" || fail "opencode: verification stdout not captured"
jq -e '.outcome.verification == "failed" and .failure_class == "verification_failed"' "$td/task.json" >/dev/null \
  || fail "opencode: failed verification not folded into the task"
grep -q '"type":"verification_failed"' "$td/events.jsonl" || fail "opencode: no verification_failed event"

# --- retry: a new Attempt on the same Task and the same session --------------

# a retry must carry the supervisor's reasoning
set +e
msg="$(run_delegate "$oc" retry "$task" "fix: narrow correction" 2>&1)"
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: retry without --reason should exit 2, got $code"
echo "$msg" | grep -q 'reason' || fail "opencode: retry error should name --reason: $msg"

: >"$stub_dir/opencode.args"
out="$(STUB_STATUS=BLOCKED run_delegate "$oc" retry "$task" --reason "typecheck still fails in foo.txt" "fix: correct the foo type")"
echo "$out" | grep -q '^ATTEMPT: attempt_002$' || fail "opencode: retry did not create attempt_002: $out"
grep -qx 'fix: correct the foo type' "$td/attempts/attempt_002/request.md" \
  || fail "opencode: correction prompt not persisted verbatim"
jq -e '.retry_of == "attempt_001" and .kind == "retry" and .session_reused == true and .requested_session == "ses_oc1"' \
  "$td/attempts/attempt_002/meta.json" >/dev/null \
  || fail "opencode: attempt_002 not linked to attempt_001: $(cat "$td/attempts/attempt_002/meta.json")"
jq -e '.reason == "typecheck still fails in foo.txt"' "$td/attempts/attempt_002/meta.json" >/dev/null \
  || fail "opencode: retry reason not persisted on the attempt"
grep -q '"decision":"retry"' "$td/events.jsonl" || fail "opencode: retry decision not recorded"

# a new attempt invalidates the previous verification rather than inheriting it
jq -e '.outcome.verification == "not_run"' "$td/task.json" >/dev/null \
  || fail "opencode: stale verification result carried into a new attempt"

STUB_STATUS=BLOCKED run_delegate "$oc" wait "$task" --poll-timeout 30 >/dev/null
grep -q -- '--session ses_oc1 fix: correct the foo type' "$stub_dir/opencode.args" \
  || fail "opencode: retry did not reuse the session: $(cat "$stub_dir/opencode.args")"

# --- BLOCKED is first class --------------------------------------------------

jq -e '.outcome.worker == "blocked" and .outcome.supervisor == "decision_required"' "$td/task.json" >/dev/null \
  || fail "opencode: BLOCKED did not surface as a supervisor decision: $(cat "$td/task.json")"
jq -e '.recommended_action == "supervisor_decision" and .failure_class == "worker_blocked"' "$td/task.json" >/dev/null \
  || fail "opencode: BLOCKED lacks a recovery recommendation"
jq -e '.worker_question | test("write-through")' "$td/attempts/attempt_002/result.json" >/dev/null \
  || fail "opencode: blocked worker's question not extracted: $(cat "$td/attempts/attempt_002/result.json")"
grep -q '"type":"worker_blocked"' "$td/events.jsonl" || fail "opencode: no worker_blocked event"

# the supervisor answers by recording a decision and resuming the same session
run_delegate "$oc" decide "$task" retry --reason "write-through; it must survive a crash" >/dev/null
jq -e '.disposition.decision == "retry" and (.disposition.reason | test("write-through"))' "$td/task.json" >/dev/null \
  || fail "opencode: supervisor decision not durable"

: >"$stub_dir/opencode.args"
out="$(run_delegate "$oc" resume ses_oc1 "Use write-through caching.")"
echo "$out" | grep -q "^TASK: $task$" || fail "opencode: resume by session did not reattach to the task: $out"
echo "$out" | grep -q '^ATTEMPT: attempt_003$' || fail "opencode: resume did not create attempt_003: $out"
run_delegate "$oc" wait "$task" --poll-timeout 30 >/dev/null
grep -q -- '--session ses_oc1 Use write-through caching.' "$stub_dir/opencode.args" \
  || fail "opencode: resume by session id did not reuse it: $(cat "$stub_dir/opencode.args")"

# --- acceptance --------------------------------------------------------------

run_delegate "$oc" verify "$task" -- true >/dev/null
jq -e '.outcome.verification == "passed"' "$td/task.json" >/dev/null || fail "opencode: passing verification not recorded"
run_delegate "$oc" decide "$task" accept --reason "diff matches the spec" >/dev/null
jq -e '.state == "accepted" and .outcome.supervisor == "accepted"' "$td/task.json" >/dev/null \
  || fail "opencode: accept did not close the task"
grep -q '"type":"task_accepted"' "$td/events.jsonl" || fail "opencode: no task_accepted event"

# an accepted task refuses further attempts rather than silently reopening
set +e
run_delegate "$oc" retry "$task" --reason "more" "again" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: retry of an accepted task should exit 2, got $code"

# --- the whole history is reconstructable from disk alone --------------------

show="$(run_delegate "$oc" show "$task" --json)"
echo "$show" | jq -e '.attempts | length == 3' >/dev/null || fail "opencode: show lost attempts: $show"
echo "$show" | jq -e '[.attempts[].session_id] | unique == ["ses_oc1"]' >/dev/null \
  || fail "opencode: show does not prove session reuse"
echo "$show" | jq -e '.attempts[1].retry_of == "attempt_001" and .attempts[2].retry_of == "attempt_002"' >/dev/null \
  || fail "opencode: attempt chain not reconstructable"
echo "$show" | jq -e '.verifications | length == 2' >/dev/null || fail "opencode: show lost verifications"
echo "$show" | jq -e '[.events[].type] | index("worker_blocked") != null and index("verification_failed") != null
                      and index("supervisor_decision") != null and index("task_accepted") != null' >/dev/null \
  || fail "opencode: event history incomplete"
echo "$show" | jq -e '[.events[].seq] == ([.events[].seq] | sort)' >/dev/null \
  || fail "opencode: event sequence is not monotonic"

run_delegate "$oc" attempts "$task" --json | jq -e 'length == 3' >/dev/null || fail "opencode: attempts --json wrong"
run_delegate "$oc" events "$task" --json | jq -e 'length > 5' >/dev/null || fail "opencode: events --json wrong"
run_delegate "$oc" logs "$task" attempt_002 --stream request | grep -q 'correct the foo type' \
  || fail "opencode: logs cannot recover an old attempt's request"
run_delegate "$oc" logs "$task" --stream report | grep -q 'STATUS: DONE' \
  || fail "opencode: logs default stream wrong"
run_delegate "$oc" list --json | jq -e 'map(select(.task_id == "'"$task"'")) | length == 1' >/dev/null \
  || fail "opencode: list does not show the task"
run_delegate "$oc" list --active --json | jq -e 'map(select(.task_id == "'"$task"'")) | length == 0' >/dev/null \
  || fail "opencode: --active still lists an accepted task"

# --- rejection and takeover --------------------------------------------------

out="$(run_delegate "$oc" run --json "reject me")"
rejected="$(echo "$out" | jq -r .task_id)"
set +e
run_delegate "$oc" decide "$rejected" take_over >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: take_over without --reason should exit 2, got $code"
run_delegate "$oc" decide "$rejected" reject --reason "two failed resumes; doing it myself" >/dev/null
jq -e '.state == "rejected"' "$(taskdir_of "$rejected")/task.json" >/dev/null \
  || fail "opencode: reject did not close the task"
run_delegate "$oc" decide "$rejected" take_over --reason "implementing in-context" >/dev/null
jq -e '.state == "taken_over"' "$(taskdir_of "$rejected")/task.json" >/dev/null \
  || fail "opencode: take_over not recorded"
grep -q '"type":"supervisor_takeover"' "$(taskdir_of "$rejected")/events.jsonl" \
  || fail "opencode: no supervisor_takeover event"

# --- concurrent retry creation and stale-Attempt fencing ---------------------

fence_task="$(run_delegate "$oc" run --json "fencing" | jq -r .task_id)"
fd="$(taskdir_of "$fence_task")"
# Model the exact crash window where attempt_001 wrote result.json but had not
# yet fenced itself, then race its detached finalizer against a real retry.
jq '.authoritative = null' "$fd/attempts/attempt_001/result.json" >"$fd/attempts/attempt_001/result.json.new"
mv "$fd/attempts/attempt_001/result.json.new" "$fd/attempts/attempt_001/result.json"
STUB_DIR="$stub_dir" XDG_STATE_HOME="$stub_dir/state" bash -c '
  set -euo pipefail
  state_root="'"$stub_dir"'/state/workflow-skills/subagents"
  agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  while [ "$(json_read "'"$fd"'/task.json" .current_attempt)" != attempt_002 ]; do sleep 0.01; done
  attempt_finalize "'"$fd"'" attempt_001
' >/dev/null &
stale_finalizer=$!
out="$(STUB_SLEEP=4 run_delegate "$oc" retry "$fence_task" --reason "exercise stale fencing" "second attempt")"
echo "$out" | grep -q '^ATTEMPT: attempt_002$' || fail "opencode: concurrent retry did not start attempt_002: $out"
wait "$stale_finalizer"
jq -e '.authoritative == false' "$fd/attempts/attempt_001/result.json" >/dev/null \
  || fail "opencode: a superseded attempt was still treated as authoritative"
jq -e '.current_attempt == "attempt_002" and .state == "running" and .outcome.worker == "pending"' "$fd/task.json" >/dev/null \
  || fail "opencode: a stale attempt overwrote current Task state"
grep -q '"type":"attempt_stale"' "$fd/events.jsonl" || fail "opencode: stale finish not recorded in history"
run_delegate "$oc" wait "$fence_task" --poll-timeout 30 >/dev/null

# Two supervisor retries serialize on the Task lock: exactly one creates the
# next Attempt and the loser observes that it is already running.
set +e
( STUB_SLEEP=4 run_delegate "$oc" retry "$fence_task" --reason "concurrent retry A" "third attempt A" >"$stub_dir/retry-a.out" 2>&1; echo $? >"$stub_dir/retry-a.code" ) &
retry_a=$!
( STUB_SLEEP=4 run_delegate "$oc" retry "$fence_task" --reason "concurrent retry B" "third attempt B" >"$stub_dir/retry-b.out" 2>&1; echo $? >"$stub_dir/retry-b.code" ) &
retry_b=$!
wait "$retry_a"
wait "$retry_b"
set -e
codes="$(sort "$stub_dir/retry-a.code" "$stub_dir/retry-b.code" | tr '\n' ' ')"
[ "$codes" = "0 2 " ] || fail "opencode: concurrent retries did not produce one winner (codes: $codes)"
jq -e '.attempt_count == 3 and .current_attempt == "attempt_003" and .state == "running"' "$fd/task.json" >/dev/null \
  || fail "opencode: concurrent retries corrupted Task state: $(cat "$fd/task.json")"
[ "$(find "$fd/attempts" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ] \
  || fail "opencode: concurrent retries created duplicate/corrupt attempt directories"
run_delegate "$oc" wait "$fence_task" --poll-timeout 30 >/dev/null

# A lock's age cannot evict a live owner. The contender must wait until the
# holder releases even after the lock directory is made artificially old.
rm -f "$stub_dir/lock-ready" "$stub_dir/lock-acquired"
STUB_DIR="$stub_dir" bash -c '
  set -euo pipefail
  state_root="'"$stub_dir"'/state/workflow-skills/subagents"; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  trap "exit 143" TERM
  lock_acquire "'"$fd"'"
  touch -d "2 minutes ago" "'"$fd"'/.lock"
  : >"'"$stub_dir"'/lock-ready"
  sleep 3
  lock_release
' &
lock_holder=$!
for _ in {1..30}; do [ -f "$stub_dir/lock-ready" ] && break; sleep 0.1; done
[ -f "$stub_dir/lock-ready" ] || fail "opencode: lock holder did not start"
STUB_DIR="$stub_dir" bash -c '
  set -euo pipefail
  state_root="'"$stub_dir"'/state/workflow-skills/subagents"; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  lock_acquire "'"$fd"'"
  : >"'"$stub_dir"'/lock-acquired"
  lock_release
' &
lock_contender=$!
sleep 1
[ ! -f "$stub_dir/lock-acquired" ] || fail "opencode: an old but live Task lock was broken"
wait "$lock_holder"
wait "$lock_contender"
[ -f "$stub_dir/lock-acquired" ] || fail "opencode: contender never acquired the released lock"

# Signal cleanup releases a held lock; a reboot/PID-reuse fingerprint mismatch
# makes an otherwise-live numeric PID stale.
rm -f "$stub_dir/signal-lock-ready"
STUB_DIR="$stub_dir" bash -c '
  set -euo pipefail
  state_root="'"$stub_dir"'/state/workflow-skills/subagents"; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  trap "exit 143" TERM
  lock_acquire "'"$fd"'"
  : >"'"$stub_dir"'/signal-lock-ready"
  sleep 30
' &
signal_holder=$!
for _ in {1..30}; do [ -f "$stub_dir/signal-lock-ready" ] && break; sleep 0.1; done
kill -TERM "$signal_holder"
set +e
wait "$signal_holder"
set -e
[ ! -d "$fd/.lock" ] || fail "opencode: Task lock survived owner signal exit"
mkdir "$fd/.lock"
printf '%s\n' "$$" >"$fd/.lock/owner.pid"
printf 'test-stale\n' >"$fd/.lock/owner.token"
jq -n --argjson pid "$$" '{pid:$pid,boot_id:"previous-boot",start_time:"1"}' >"$fd/.lock/process.json"
STUB_DIR="$stub_dir" bash -c '
  set -euo pipefail
  state_root="'"$stub_dir"'/state/workflow-skills/subagents"; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  lock_acquire "'"$fd"'"
  lock_release
' || fail "opencode: stale fingerprint lock was not recoverable"

# Concurrent event writers preserve valid JSONL and a gap-free unique sequence.
for i in {1..12}; do
  STUB_DIR="$stub_dir" bash -c '
    set -euo pipefail
    state_root="'"$stub_dir"'/state/workflow-skills/subagents"; agent_name=workflow-worker
    . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
    event_append "'"$fd"'" audit_probe "$(jq -cn --arg writer "'"$i"'" "{writer:\$writer}")"
  ' &
done
wait
jq -s -e '([.[].seq] == [range(1; length + 1)]) and ([.[].seq] | unique | length) == length' \
  "$fd/events.jsonl" >/dev/null || fail "opencode: concurrent event append broke JSONL or event sequences"
jq -s -e '[.[] | select(.type == "worker_done" and .attempt == "attempt_003")] | length == 1' \
  "$fd/events.jsonl" >/dev/null || fail "opencode: duplicate terminal event recorded for attempt_003"

# --- liveness, cancellation and recovery -------------------------------------

# a still-running attempt polls out with exit 3 and reports liveness
: >"$stub_dir/opencode.args"
out="$(STUB_SLEEP=6 run_delegate "$oc" "slow task")"
task="$(task_of "$out")"
td="$(taskdir_of "$task")"
set +e
res="$(run_delegate "$oc" --wait "$task" --poll-timeout 1)"
code=$?
set -e
[ "$code" -eq 3 ] || fail "opencode: running wait should exit 3, got $code"
echo "$res" | grep -q '^RUNNING' || fail "opencode: no RUNNING line: $res"
echo "$res" | grep -q 'possibly_stalled=false' || fail "opencode: no liveness in RUNNING line: $res"
# a poll reports progress in one line; the six-line watch block belongs to the
# launch that printed it once, not to every poll
echo "$res" | grep -q '^WATCH:' && fail "opencode: a poll must not reprint the watch block: $res"
echo "$res" | grep -qE '^RUNNING .*returned=' || fail "opencode: RUNNING line lost its return reason: $res"
set +e
res="$(run_delegate "$oc" status "$task" --json)"
set -e
echo "$res" | jq -e '.liveness.process_alive == true and .task_state == "running"' >/dev/null \
  || fail "opencode: liveness missing from status --json: $res"

# the session export feeds provider progress while the fresh run is still going
for _ in 1 2 3; do
  if grep -q 'slow task' "$td/attempts/attempt_001/provider-progress.json"; then break; fi
  sleep 1
done
grep -q 'slow task' "$td/attempts/attempt_001/provider-progress.json" \
  || fail "opencode: fresh-run provider progress stayed empty"
[ ! -f "$td/attempts/attempt_001/result.json" ] \
  || fail "opencode: progress check ran after the attempt ended; it proves nothing"

# idle must come from what the provider recorded, not from the snapshot file's
# mtime: the poller rewrites that file on a fixed interval, so its age can never
# exceed the poll interval and possibly_stalled could never fire
adir="$td/attempts/$(jq -r '.current_attempt' "$td/task.json")"
jq -n --argjson t "$(( $(date +%s) * 1000 - 4000 * 1000 ))" '[{time_created: $t, type: "text"}]' \
  >"$adir/provider-progress.json"
touch "$adir/provider-progress.json" "$adir/raw.jsonl"
set +e
res="$(run_delegate "$oc" status "$task" --json)"
set -e
echo "$res" | jq -e '.liveness.last_provider_activity_seconds > 3000' >/dev/null \
  || fail "opencode: provider activity read from file mtime, not recorded rows: $res"

# verification must not run inside the worker's turn
set +e
msg="$(run_delegate "$oc" verify "$task" -- true 2>&1)"
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: verify during a running attempt should exit 2, got $code"
echo "$msg" | grep -q "outside the worker's turn" || fail "opencode: verify refusal unclear: $msg"

res="$(run_delegate "$oc" --wait "$task" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: slow job did not finish clean: $res"

# `cancel --keep-task` stops the attempt but leaves the Task retryable
out="$(STUB_SLEEP=30 run_delegate "$oc" start "long task")"
task="$(task_of "$out")"
td="$(taskdir_of "$task")"
sleep 2
set +e
res="$(run_delegate "$oc" cancel "$task" --keep-task --reason "stalled")"
code=$?
set -e
[ "$code" -eq 130 ] || fail "opencode: cancel should exit 130, got $code"
echo "$res" | grep -q '^TRANSPORT: cancelled$' || fail "opencode: cancel result unhelpful: $res"
jq -e '.state == "awaiting_supervisor"' "$td/task.json" >/dev/null \
  || fail "opencode: --keep-task should not close the Task"
run_delegate "$oc" retry "$task" --reason "re-run after the stall" "continue" >/dev/null
run_delegate "$oc" wait "$task" --poll-timeout 30 >/dev/null
jq -e '.attempt_count == 2' "$td/task.json" >/dev/null || fail "opencode: retry after cancel did not run"

# a plain `cancel` closes the Task
out="$(STUB_SLEEP=30 run_delegate "$oc" start "cancel me")"
task="$(task_of "$out")"
sleep 2
set +e
run_delegate "$oc" cancel "$task" >/dev/null
code=$?
set -e
[ "$code" -eq 130 ] || fail "opencode: plain cancel should exit 130, got $code"
jq -e '.state == "cancelled"' "$(taskdir_of "$task")/task.json" >/dev/null \
  || fail "opencode: plain cancel did not close the Task"
cancelled_ad="$(taskdir_of "$task")/attempts/attempt_001"
STUB_DIR="$stub_dir" bash -c '
  state_root="'"$stub_dir"'/state/workflow-skills/subagents"; agent_name=workflow-worker
  . "'"$repo_root"'/skills/opencode-subagent/scripts/orchestration.sh"
  ! attempt_alive "'"$cancelled_ad"'"
' || fail "opencode: cancel left the provider process alive"

# A vanished detached supervisor does not make its still-running provider dead.
# Once both processes are gone, recovery records the interrupted Attempt.
out="$(STUB_SLEEP=30 run_delegate "$oc" start "interrupted")"
task="$(task_of "$out")"
td="$(taskdir_of "$task")"
sleep 2
kill -9 "$(cat "$td/attempts/attempt_001/pid")" 2>/dev/null || true
sleep 1
run_delegate "$oc" recover --json | jq -e 'map(select(.task_id == "'"$task"'"))[0].reconciliation == "running"' >/dev/null \
  || fail "opencode: recover ignored a live provider after its supervisor vanished"
provider_pid="$(cat "$td/attempts/attempt_001/provider.pid")"
kill -9 -- "-$provider_pid" 2>/dev/null || kill -9 "$provider_pid" 2>/dev/null || true
sleep 1
run_delegate "$oc" recover --json | jq -e 'map(select(.task_id == "'"$task"'"))[0].reconciliation == "interrupted"' >/dev/null \
  || fail "opencode: recover did not reconcile the interrupted attempt"
jq -e '.state == "awaiting_supervisor" and .failure_class == "interrupted"' "$td/task.json" >/dev/null \
  || fail "opencode: interrupted attempt left the Task inconsistent"
grep -q '"type":"task_reconciled"' "$td/events.jsonl" || fail "opencode: reconciliation not recorded"
before_recover_events="$(wc -l <"$td/events.jsonl")"
before_recover_state="$(sha256sum "$td/task.json" | awk '{print $1}')"
run_delegate "$oc" recover --json >/dev/null
[ "$(wc -l <"$td/events.jsonl")" -eq "$before_recover_events" ] \
  || fail "opencode: repeated recover appended duplicate semantic events"
[ "$(sha256sum "$td/task.json" | awk '{print $1}')" = "$before_recover_state" ] \
  || fail "opencode: repeated recover mutated already-reconciled Task state"

# kill -0 alone is insufficient: a boot/start fingerprint mismatch is treated
# as a dead prior process even when that numeric PID is currently alive.
finger_task="$(run_delegate "$oc" run --json "fingerprint recovery" | jq -r .task_id)"
finger_dir="$(taskdir_of "$finger_task")"
rm -f "$finger_dir/attempts/attempt_001/result.json"
printf '%s\n' "$$" >"$finger_dir/attempts/attempt_001/pid"
jq -n --argjson pid "$$" '{pid:$pid,boot_id:"previous-boot",start_time:"1"}' \
  >"$finger_dir/attempts/attempt_001/process.json"
jq '.state = "running" | .outcome.transport = "running" | .outcome.worker = "pending"' \
  "$finger_dir/task.json" >"$finger_dir/task.json.new"
mv "$finger_dir/task.json.new" "$finger_dir/task.json"
run_delegate "$oc" recover --json | jq -e 'map(select(.task_id == "'"$finger_task"'"))[0].reconciliation == "interrupted"' >/dev/null \
  || fail "opencode: reboot/PID-reuse fingerprint mismatch was treated as live"

# a result written but never folded in is picked up on the next recover
out="$(run_delegate "$oc" run --json "unfolded")"
task="$(echo "$out" | jq -r .task_id)"
td="$(taskdir_of "$task")"
jq '.state = "running" | .outcome.transport = "running" | .outcome.worker = "pending"' "$td/task.json" >"$td/task.json.new"
mv "$td/task.json.new" "$td/task.json"
run_delegate "$oc" recover --json | jq -e 'map(select(.task_id == "'"$task"'"))[0].reconciliation == "finalized"' >/dev/null \
  || fail "opencode: recover did not fold in an orphaned result"
jq -e '.outcome.worker == "done"' "$td/task.json" >/dev/null || fail "opencode: recover lost the worker outcome"

# A command that cannot be executed is auditable and distinct from a command
# that ran and failed its verification assertions.
verify_error_task="$(run_delegate "$oc" run --json "verification infrastructure" | jq -r .task_id)"
verify_error_dir="$(taskdir_of "$verify_error_task")"
set +e
run_delegate "$oc" verify "$verify_error_task" -- command-that-does-not-exist-workflow-skills >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: verification execution error should exit 2, got $code"
jq -e '.result == "error" and .exit_code == 127' "$verify_error_dir/verifications/ver_001.json" >/dev/null \
  || fail "opencode: verification execution error was not recorded distinctly"
jq -e '.outcome.verification == "error" and .failure_class == "verification_error"
       and .recommended_action == "repair_infrastructure"' "$verify_error_dir/task.json" >/dev/null \
  || fail "opencode: verification execution error was folded incorrectly"

# --- preserved transport behaviour -------------------------------------------

# the hard timeout kills the attempt and records it as such
out="$(STUB_SLEEP=30 run_delegate "$oc" --timeout 1 "never finishes")"
task="$(task_of "$out")"
set +e
run_delegate "$oc" --wait "$task" --poll-timeout 30 >/dev/null
code=$?
set -e
[ "$code" -eq 124 ] || fail "opencode: timeout should surface exit 124, got $code"
jq -e '.outcome.transport == "timeout" and .failure_class == "timeout"' "$(taskdir_of "$task")/task.json" >/dev/null \
  || fail "opencode: status not marked timeout"

# conf default applies when the user names no model
: >"$stub_dir/opencode.args"
launch_and_wait "$oc" "conf task" >/dev/null
grep -q -- '--model stub/conf-model' "$stub_dir/opencode.args" \
  || fail "opencode: conf default not applied: $(cat "$stub_dir/opencode.args")"

# explicit --model beats the conf
: >"$stub_dir/opencode.args"
launch_and_wait "$oc" --model explicit/model "task" >/dev/null
grep -q -- '--model explicit/model' "$stub_dir/opencode.args" \
  || fail "opencode: explicit model not passed: $(cat "$stub_dir/opencode.args")"

# --save-default writes the conf (idempotently: one line per key)
launch_and_wait "$oc" --model saved/model --save-default "task" >/dev/null
launch_and_wait "$oc" --model saved/model --save-default "task" >/dev/null
count="$(grep -c '^OPENCODE_SUBAGENT_MODEL=' "$conf_file")"
[ "$count" -eq 1 ] || fail "opencode: conf key duplicated (count=$count)"
grep -q '^OPENCODE_SUBAGENT_MODEL=saved/model$' "$conf_file" || fail "opencode: --save-default not written"

# with no model anywhere the CLI is never reached: no silent fall back to
# whatever model opencode happens to be configured with globally
rm -f "$conf_file"
: >"$stub_dir/opencode.args"
set +e
run_delegate "$oc" "plain task" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: unconfigured launch should exit 2, got $code"
[ ! -s "$stub_dir/opencode.args" ] || fail "opencode: invoked the CLI without a resolved worker model"
echo 'OPENCODE_SUBAGENT_MODEL=stub/conf-model' >"$conf_file"

# the --resume flag still adopts a session on a fresh launch
: >"$stub_dir/opencode.args"
launch_and_wait "$oc" --resume ses_legacy "fix: rename foo" >/dev/null
grep -q -- '--session ses_legacy fix: rename foo' "$stub_dir/opencode.args" \
  || fail "opencode: --resume did not pass --session: $(cat "$stub_dir/opencode.args")"

# a provider-final response completes a resume even when the CLI event stream hangs
: >"$stub_dir/opencode.args"
out="$(STUB_RESUME_HANG=1 run_delegate "$oc" --resume ses_hang "fix: hung stream")"
task="$(task_of "$out")"
res="$(run_delegate "$oc" --wait "$task" --poll-timeout 30)"
echo "$res" | grep -q '^SESSION: ses_hang$' || fail "opencode: recovered resume session missing: $res"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: provider-complete resume did not finish cleanly: $res"
grep -q 'STATUS: DONE' "$(taskdir_of "$task")/attempts/attempt_001/worker-report.txt" \
  || fail "opencode: recovered resume provider report missing"

# the same provider-final detection protects a fresh run with a hung event stream
out="$(STUB_FRESH_HANG=1 run_delegate "$oc" "hung fresh stream")"
task="$(task_of "$out")"
res="$(run_delegate "$oc" --wait "$task" --poll-timeout 10)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: provider-complete fresh run did not finish cleanly: $res"

# exit 0 without a provider-final response is incomplete, not successful
out="$(STUB_NO_FINAL=1 run_delegate "$oc" "incomplete task")"
task="$(task_of "$out")"
set +e
res="$(STUB_NO_FINAL=1 run_delegate "$oc" --wait "$task" --poll-timeout 30)"
code=$?
set -e
[ "$code" -eq 4 ] || fail "opencode: incomplete provider turn should exit 4, got $code"
jq -e '.outcome.transport == "incomplete" and .outcome.worker == "no_report"' \
  "$(taskdir_of "$task")/task.json" >/dev/null || fail "opencode: incomplete turn misclassified"
jq -e '.failure_class == "provider_turn_incomplete" and .recommended_action == "resume_same_session"' \
  "$(taskdir_of "$task")/task.json" >/dev/null || fail "opencode: incomplete turn lacks recovery guidance"
echo "$res" | grep -q 'before producing a provider-final response' \
  || fail "opencode: incomplete turn lacks actionable report: $res"

# session export failures fall back to CLI output and still finalize job state
out="$(STUB_EXPORT_FAIL=1 run_delegate "$oc" "export fallback")"
task="$(task_of "$out")"
res="$(run_delegate "$oc" --wait "$task" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: export failure replaced successful CLI exit: $res"
# the report survived and was parsed: its status became the worker outcome and
# its VERIFICATION text is rendered
echo "$res" | grep -q '^WORKER: done$' || fail "opencode: export failure lost the CLI report's status: $res"
echo "$res" | grep -q 'stub check -> pass' || fail "opencode: export failure lost the CLI report body: $res"
jq -e '.outcome.transport == "finished"' "$(taskdir_of "$task")/task.json" >/dev/null \
  || fail "opencode: export failure stranded running status"

# A real 2.x client may exit before its final JSONL write reaches the file.
# The old runner stored earlier progress text as no_report while the final
# STATUS block arrived after the runner had finalized.
out="$(STUB_LATE_FINAL=1 STUB_EXPORT_FAIL=1 run_delegate "$oc" run --json "late final stream")"
echo "$out" | jq -e '.outcome.worker == "done" and (.report | contains("STATUS: DONE"))' >/dev/null \
  || fail "opencode: a late final stream write was recorded as no_report: $out"

# Export can remain empty during a live turn. Stream events still carry useful
# tool activity and timestamps for the progress file and stall calculation.
out="$(STUB_EXPORT_FAIL=1 STUB_SLEEP=4 run_delegate "$oc" start "stream progress fallback")"
task="$(task_of "$out")"
for _ in 1 2 3; do
  if jq -e 'length > 0' "$(taskdir_of "$task")/attempts/attempt_001/provider-progress.json" >/dev/null 2>&1; then break; fi
  sleep 1
done
jq -e 'length > 0 and .[0].time_created != null' "$(taskdir_of "$task")/attempts/attempt_001/provider-progress.json" >/dev/null \
  || fail "opencode: live stream activity was absent from provider-progress.json"
STUB_EXPORT_FAIL=1 run_delegate "$oc" wait "$task" --poll-timeout 30 >/dev/null

# an unknown provider finish value is schema drift, not proof of incompleteness
out="$(STUB_FINISH_DRIFT=1 run_delegate "$oc" "finish drift")"
task="$(task_of "$out")"
res="$(run_delegate "$oc" --wait "$task" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: finish-state drift caused false exit 4: $res"

# session ids reach the CLI as one argument, never interpolated into a query
: >"$stub_dir/opencode-export.args"
launch_and_wait "$oc" --resume "abc' OR '1'='1" "quote session" >/dev/null
grep -Fxq "abc' OR '1'='1" "$stub_dir/opencode-export.args" \
  || fail "opencode: resume session id did not reach session export verbatim: $(cat "$stub_dir/opencode-export.args")"

# the stream alone completes a turn: 2.x never emits step_finish after the
# closing text, and that must not read as an incomplete turn
out="$(STUB_EXPORT_FAIL=1 STUB_STEPS=2 run_delegate "$oc" "stream only, tool step first")"
task="$(task_of "$out")"
res="$(run_delegate "$oc" --wait "$task" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: a 2.x stream without a closing step_finish was not complete: $res"
echo "$res" | grep -q '^WORKER: done$' || fail "opencode: 2.x stream report not parsed: $res"

# a turn that ended on a tool step is incomplete even when the export cannot be read
out="$(STUB_EXPORT_FAIL=1 STUB_NO_FINAL=1 run_delegate "$oc" "stream only, no final text")"
task="$(task_of "$out")"
set +e
run_delegate "$oc" --wait "$task" --poll-timeout 30 >/dev/null
code=$?
set -e
[ "$code" -eq 4 ] || fail "opencode: a stream ending on a tool step should exit 4, got $code"

# a resumed attempt reports its own turn, never the session's earlier final answer
out="$(run_delegate "$oc" run --json "first turn for resume")"
res_task="$(echo "$out" | jq -r .task_id)"
out="$(STUB_NO_FINAL=1 STUB_EXPORT_FAIL=0 run_delegate "$oc" retry "$res_task" --reason "baseline check" "second turn")"
set +e
STUB_NO_FINAL=1 run_delegate "$oc" wait "$res_task" --poll-timeout 30 >/dev/null
code=$?
set -e
[ "$code" -eq 4 ] || fail "opencode: resumed attempt adopted the previous turn's final answer (exit $code)"
run_delegate "$oc" decide "$res_task" reject --reason "baseline fixture" >/dev/null || true

# provider errors arrive in the 2.x stream, not on stderr, and still classify
out="$(STUB_STREAM_ERROR='Unauthorized: invalid api key' run_delegate "$oc" "auth failure")"
task="$(task_of "$out")"
# wait returns early on a stream error; the runner finalizes just after
for _ in $(seq 1 20); do
  [ -f "$(taskdir_of "$task")/attempts/attempt_001/result.json" ] && break
  sleep 0.5
done
jq -e '.failure_class == "authentication_error" and .recommended_action == "repair_infrastructure"' \
  "$(taskdir_of "$task")/task.json" >/dev/null \
  || fail "opencode: stream-reported auth error misclassified: $(jq -c '{failure_class, recommended_action}' "$(taskdir_of "$task")/task.json")"

# --cwd runs the worker in that tree: 2.x has no --dir, so it is never passed
: >"$stub_dir/opencode.args"
: >"$stub_dir/opencode.pwd"
cwd_repo="$stub_dir/work-cwd"
mkdir -p "$cwd_repo"
out="$(cd "$stub_dir" && run_delegate "$oc" run --json --cwd work-cwd "cwd task")"
cwd_task="$(echo "$out" | jq -r .task_id)"
grep -q -- '--dir' "$stub_dir/opencode.args" && fail "opencode: passed --dir, which 2.x rejects: $(cat "$stub_dir/opencode.args")"
[ "$(tail -1 "$stub_dir/opencode.pwd")" = "$cwd_repo" ] \
  || fail "opencode: worker did not run in --cwd: $(cat "$stub_dir/opencode.pwd")"
jq -e --arg d "$cwd_repo" '.cwd == $d' "$(taskdir_of "$cwd_task")/task.json" >/dev/null \
  || fail "opencode: relative --cwd not recorded as an absolute path: $(jq -r .cwd "$(taskdir_of "$cwd_task")/task.json")"
# and a retry from anywhere else reuses that tree, still without --dir
: >"$stub_dir/opencode.pwd"
(cd / && run_delegate "$oc" retry "$cwd_task" --reason "cwd retry" "again" >/dev/null)
run_delegate "$oc" wait "$cwd_task" --poll-timeout 30 >/dev/null
[ "$(tail -1 "$stub_dir/opencode.pwd")" = "$cwd_repo" ] \
  || fail "opencode: retry did not run in the Task's tree: $(cat "$stub_dir/opencode.pwd")"
grep -q -- '--dir' "$stub_dir/opencode.args" && fail "opencode: retry passed --dir: $(cat "$stub_dir/opencode.args")"
run_delegate "$oc" decide "$cwd_task" accept --reason "cwd fixture" >/dev/null

# a --cwd that does not exist is a usage error before any Task exists
set +e
run_delegate "$oc" --cwd "$stub_dir/no-such-dir" "task" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: missing --cwd should exit 2, got $code"

# OpenCode 1.x is refused as infrastructure before a Task exists or the CLI runs
: >"$stub_dir/opencode.args"
set +e
msg="$(STUB_VERSION=1.18.32 run_delegate "$oc" "old cli" 2>&1)"
code=$?
set -e
[ "$code" -eq 127 ] || fail "opencode: OpenCode 1.x should exit 127, got $code"
echo "$msg" | grep -q 'needs OpenCode 2' || fail "opencode: unsupported-version error unclear: $msg"
[ ! -s "$stub_dir/opencode.args" ] || fail "opencode: launched a worker on an unsupported CLI"

# the session id is recorded before the stream says anything, so a cancel
# during a slow first response still leaves something to resume
out="$(STUB_SESSION=ses_silent STUB_SILENT_SLEEP=30 run_delegate "$oc" start "silent start")"
task="$(task_of "$out")"
for _ in $(seq 1 10); do
  [ "$(jq -r '.session_id // ""' "$(taskdir_of "$task")/task.json")" = "ses_silent" ] && break
  sleep 0.5
done
set +e
run_delegate "$oc" cancel "$task" >/dev/null
set -e
jq -e '.session_id == "ses_silent"' "$(taskdir_of "$task")/task.json" >/dev/null \
  || fail "opencode: session not discovered before the first stream event: $(jq -c '{session_id}' "$(taskdir_of "$task")/task.json")"

# `help` is a subcommand, not a task
out="$(run_delegate "$oc" help)"
echo "$out" | grep -q 'Legacy forms still accepted' || fail "opencode: help subcommand did not print usage: $out"

# --- usage errors ------------------------------------------------------------

# --save-default without --model is a usage error
if run_delegate "$oc" --save-default "task" >/dev/null 2>&1; then
  fail "opencode: --save-default without --model should exit nonzero"
fi

# missing spec fails with usage error
if run_delegate "$oc" --model x/y >/dev/null 2>&1; then
  fail "opencode: missing spec should exit nonzero"
fi

# `resume` without a session id is a usage error
if run_delegate "$oc" resume >/dev/null 2>&1; then
  fail "opencode: resume without a session id should exit nonzero"
fi

# waiting on an unknown task fails with exit 2
set +e
run_delegate "$oc" --wait no-such-task >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: unknown task should exit 2, got $code"

# missing CLI fails loudly with 127 and points at --doctor
set +e
msg="$(STUB_DIR="$stub_dir" PATH="/usr/bin:/bin" bash "$oc" "task" 2>&1)"
code=$?
set -e
[ "$code" -eq 127 ] || fail "opencode: missing CLI should exit 127, got $code"
echo "$msg" | grep -q 'doctor' || fail "opencode: missing-CLI error should mention --doctor: $msg"

# --- explicit operations ----------------------------------------------------

# `start` is the async half of the API and matches the legacy launch form
: >"$stub_dir/opencode.args"
out="$(STUB_SLEEP=4 run_delegate "$oc" start --model async/model "async task")"
task="$(task_of "$out")"
[ -n "$task" ] || fail "opencode: start printed no task id: $out"

# `status` reports the running task without blocking on it
set +e
res="$(run_delegate "$oc" status "$task")"
code=$?
set -e
[ "$code" -eq 3 ] || fail "opencode: status of a running task should exit 3, got $code"
echo "$res" | grep -q '^RUNNING' || fail "opencode: status of a running task lacks RUNNING: $res"

# ... and `wait` then blocks until it is done
res="$(run_delegate "$oc" wait "$task" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: start/wait flow did not finish clean: $res"
set +e
res="$(run_delegate "$oc" status "$task")"
code=$?
set -e
[ "$code" -eq 0 ] || fail "opencode: status of a finished task should exit 0, got $code"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: status of a finished task lacks the result: $res"

# `run` blocks and returns the result in one call
: >"$stub_dir/opencode.args"
res="$(run_delegate "$oc" run --model blocking/model "blocking task")"
echo "$res" | grep -q '^TASK: task_' || fail "opencode: run did not report its task id: $res"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: run did not block through completion: $res"
echo "$res" | grep -q '^WORKER: done$' || fail "opencode: run lost the report: $res"
echo "$res" | grep -q 'stub check -> pass' || fail "opencode: run lost the report body: $res"
grep -q -- '--model blocking/model' "$stub_dir/opencode.args" || fail "opencode: run dropped --model"

# `retry --new-session` deliberately abandons the session
: >"$stub_dir/opencode.args"
task="$(run_delegate "$oc" run --json "session reset" | jq -r .task_id)"
run_delegate "$oc" retry "$task" --new-session --reason "session context is poisoned" "start over" >/dev/null
run_delegate "$oc" wait "$task" --poll-timeout 30 >/dev/null
jq -e '.session_reused == false' "$(taskdir_of "$task")/attempts/attempt_002/meta.json" >/dev/null \
  || fail "opencode: --new-session still reused the session"

# --- machine-readable output ------------------------------------------------

# start --json describes the running task
out="$(run_delegate "$oc" start --json --model json/model "json task")"
echo "$out" | jq -e '.state == "running"' >/dev/null || fail "opencode: start --json state wrong: $out"
echo "$out" | jq -e '.model == "json/model"' >/dev/null || fail "opencode: start --json model wrong: $out"
echo "$out" | jq -e '.agent == "workflow-worker"' >/dev/null || fail "opencode: start --json agent wrong: $out"
echo "$out" | jq -e '.session_id == null or .session_id == "ses_oc1"' >/dev/null \
  || fail "opencode: start --json exposed an invalid session: $out"
echo "$out" | jq -e '.task_id | startswith("task_")' >/dev/null || fail "opencode: start --json task_id wrong: $out"
echo "$out" | jq -e '.job_id == .task_id' >/dev/null || fail "opencode: job_id alias missing: $out"
echo "$out" | jq -e '.cwd != null' >/dev/null || fail "opencode: start --json cwd missing: $out"
task="$(echo "$out" | jq -r .task_id)"

# wait --json describes the completed task
res="$(run_delegate "$oc" wait "$task" --json --poll-timeout 30)"
echo "$res" | jq -e '.state == "completed"' >/dev/null || fail "opencode: wait --json state wrong: $res"
echo "$res" | jq -e '.exit_code == 0' >/dev/null || fail "opencode: wait --json exit_code wrong: $res"
echo "$res" | jq -e '.session_id == "ses_oc1"' >/dev/null || fail "opencode: wait --json session wrong: $res"
echo "$res" | jq -e '.cost_usd == 0.0042' >/dev/null || fail "opencode: wait --json cost wrong: $res"
echo "$res" | jq -e '.report | test("STATUS: DONE")' >/dev/null || fail "opencode: wait --json report wrong: $res"
echo "$res" | jq -e '.changed_files | type == "array"' >/dev/null || fail "opencode: wait --json changed_files not an array: $res"
echo "$res" | jq -e '.outcome | has("transport") and has("worker") and has("verification") and has("supervisor")' >/dev/null \
  || fail "opencode: wait --json lacks the four outcome dimensions: $res"

# changed_files reports what the worker touched in the worktree
work_repo="$stub_dir/work"
mkdir -p "$work_repo"
git -C "$work_repo" init -q
res="$(cd "$work_repo" && run_delegate "$oc" run --json "touch-artifact")"
echo "$res" | jq -e '.changed_files | index("worker-artifact.txt")' >/dev/null \
  || fail "opencode: changed_files did not report the worker's new file: $res"

# the tree diff is split, never filtered: the worker's own list attributes part
# of it, and the rest is reported as unattributed rather than dropped. The
# reported path is backticked and annotated, as real workers write it.
split_repo="$stub_dir/work-split"
mkdir -p "$split_repo"
git -C "$split_repo" init -q
res="$(cd "$split_repo" && STUB_FILES='- `worker-artifact.txt` (new — placeholder)' \
  run_delegate "$oc" run --json "touch-two")"
echo "$res" | jq -e '(.changed_files | index("worker-artifact.txt")) and (.changed_files | index("other-artifact.txt"))' >/dev/null \
  || fail "opencode: changed_files must keep the whole tree diff: $res"
echo "$res" | jq -e '.worker_attributed_files == ["worker-artifact.txt"]' >/dev/null \
  || fail "opencode: backticked/annotated worker path was not attributed: $(echo "$res" | jq -c '{worker_attributed_files, unattributed_files}')"
echo "$res" | jq -e '.unattributed_files == ["other-artifact.txt"]' >/dev/null \
  || fail "opencode: file the worker did not report is not flagged unattributed: $res"

# a worker that reports no files at all must not empty the supervisor's review
prose_repo="$stub_dir/work-prose"
mkdir -p "$prose_repo"
git -C "$prose_repo" init -q
res="$(cd "$prose_repo" && STUB_FILES='- Stage 1 core domain files' \
  run_delegate "$oc" run --json "touch-artifact")"
echo "$res" | jq -e '(.changed_files | length) > 0 and (.worker_attributed_files | length) == 0' >/dev/null \
  || fail "opencode: prose FILES_CHANGED must attribute nothing yet keep the diff: $res"

# a sibling delegation still editing the same tree also blocks verification:
# the one-per-worktree rule used to guarantee this implicitly
sib_repo="$stub_dir/work-sibling"
mkdir -p "$sib_repo"
git -C "$sib_repo" init -q
done_out="$(cd "$sib_repo" && run_delegate "$oc" run --json "quick task")"
done_task="$(echo "$done_out" | jq -r .task_id)"

# a live sibling, planted rather than raced: a Task in the same tree whose
# current attempt has not written a result
sib_task="task_sibling_live"
sib_dir="$(taskdir_of "$sib_task")"
mkdir -p "$sib_dir/attempts/attempt_001"
jq -n --arg cwd "$sib_repo" \
  '{schema: 2, task_id: "task_sibling_live", state: "running", cwd: $cwd,
    current_attempt: "attempt_001", attempt_count: 1}' >"$sib_dir/task.json"

set +e
msg="$(cd "$sib_repo" && run_delegate "$oc" verify "$done_task" -- true 2>&1)"
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: verify with a live sibling in the tree should exit 2, got $code"
echo "$msg" | grep -q "$sib_task" || fail "opencode: verify refusal must name the blocking Task: $msg"

# a live Task in a DIFFERENT tree must not block it
jq -n '{schema: 2, task_id: "task_sibling_live", state: "running", cwd: "/nonexistent/other/tree",
        current_attempt: "attempt_001", attempt_count: 1}' >"$sib_dir/task.json"
(cd "$sib_repo" && run_delegate "$oc" verify "$done_task" -- true) >/dev/null \
  || fail "opencode: a live Task in another tree must not block verification"
rm -rf "$sib_dir"

# --- event-driven wait ------------------------------------------------------

# wait returns early when the provider goes quiet for longer than the stall
# threshold, with its own exit code: exit 3 tells the supervisor to poll again,
# which for a stall would spin until the hard timeout
stall_repo="$stub_dir/work-stall"
mkdir -p "$stall_repo"
git -C "$stall_repo" init -q
export STUB_SLEEP=25
out="$(cd "$stall_repo" && run_delegate "$oc" start "stalling task")"
unset STUB_SLEEP
stall_task="$(task_of "$out")"
stall_dir="$(taskdir_of "$stall_task")"
stall_adir="$stall_dir/attempts/attempt_001"
# the provider recorded nothing for an hour
jq -n --argjson t "$(( ($(date +%s) - 3600) * 1000 ))" '[{time_created: $t, type: "text"}]' \
  >"$stall_adir/provider-progress.json"
set +e
res="$(run_delegate "$oc" wait "$stall_task" --poll-timeout 30 --stall-seconds 5)"
code=$?
set -e
[ "$code" -eq 5 ] || fail "opencode: a stalled wait should exit 5, got $code: $res"
echo "$res" | grep -q 'returned=stalled' || fail "opencode: stalled return is indistinguishable from a poll timeout: $res"

# and it is return-only: the attempt is left running, never cancelled
set +e
res="$(run_delegate "$oc" status "$stall_task" --json)"
set -e
echo "$res" | jq -e '.task_state != "cancelled" and .outcome.transport != "cancelled"' >/dev/null \
  || fail "opencode: a stalled wait must not cancel the attempt: $res"
if grep -q 'attempt_cancelled' "$stall_dir/events.jsonl"; then
  fail "opencode: a stalled wait recorded a cancellation"
fi

# --no-stall-return restores plain blocking, which is what `run` relies on
set +e
res="$(run_delegate "$oc" wait "$stall_task" --poll-timeout 2 --stall-seconds 5 --no-stall-return)"
code=$?
set -e
[ "$code" -eq 3 ] || fail "opencode: --no-stall-return should poll out with 3, got $code"

# a provider error in the stream also returns early
echo '{"type":"error","sessionID":"ses_oc1","error":{"name":"APIError","data":{"statusCode":403}}}' \
  >>"$stall_adir/raw.jsonl"
set +e
res="$(run_delegate "$oc" wait "$stall_task" --poll-timeout 30 --stall-seconds 99999)"
code=$?
set -e
echo "$res" | grep -q 'returned=provider_error' || fail "opencode: provider error did not end the wait: $res"
run_delegate "$oc" cancel "$stall_task" >/dev/null 2>&1 || true

# --- wait --any -------------------------------------------------------------

any_repo="$stub_dir/work-any"
mkdir -p "$any_repo"
git -C "$any_repo" init -q
done_a="$(cd "$any_repo" && run_delegate "$oc" run --json "any task a" | jq -r .task_id)"

# a live Task, planted so the table has one of each
live_task="task_any_live"
live_dir="$(taskdir_of "$live_task")"
mkdir -p "$live_dir/attempts/attempt_001"
jq -n --arg cwd "$any_repo" '{schema: 2, task_id: "task_any_live", state: "running", cwd: $cwd,
    current_attempt: "attempt_001", attempt_count: 1}' >"$live_dir/task.json"
jq -n --argjson t "$(date +%s)" '{started_epoch: $t, kind: "initial"}' \
  >"$live_dir/attempts/attempt_001/meta.json"

# one terminal Task among them means there is something to look at: exit 0
set +e
res="$(run_delegate "$oc" wait --any "$done_a" "$live_task" --poll-timeout 1)"
code=$?
set -e
[ "$code" -eq 0 ] || fail "opencode: wait --any with a finished task should exit 0, got $code: $res"
echo "$res" | grep -q "$done_a" || fail "opencode: wait --any table omits a task: $res"
echo "$res" | grep -q "$live_task" || fail "opencode: wait --any table omits the running task: $res"

# all still running: exit 3
set +e
res="$(run_delegate "$oc" wait --any "$live_task" --poll-timeout 1)"
code=$?
set -e
[ "$code" -eq 3 ] || fail "opencode: wait --any with nothing terminal should exit 3, got $code"

# --json returns one object per task
res="$(run_delegate "$oc" wait --any "$done_a" "$live_task" --poll-timeout 1 --json)"
echo "$res" | jq -e 'length == 2 and (.[0] | has("task_id"))' >/dev/null \
  || fail "opencode: wait --any --json is not one object per task: $res"

# an unknown id is an error, not a silently short table
set +e
run_delegate "$oc" wait --any "$done_a" task_does_not_exist >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: wait --any with an unknown task should exit 2, got $code"

# --any without wait must not fall through to a launch
set +e
msg="$(run_delegate "$oc" --any "$done_a" 2>&1)"
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: bare --any should exit 2, got $code: $msg"
rm -rf "$live_dir"

# --- stale-Task note --------------------------------------------------------

# a Task that finished and never got a decision is invisible until someone goes
# looking; say so, but only for the tree in front of us, and only on stderr
note_repo="$stub_dir/work-note"
other_repo="$stub_dir/work-note-other"
mkdir -p "$note_repo" "$other_repo"
git -C "$note_repo" init -q
git -C "$other_repo" init -q
note_task="$(cd "$note_repo" && run_delegate "$oc" run --json "undecided task" | jq -r .task_id)"

err="$(cd "$note_repo" && run_delegate "$oc" list 2>&1 >/dev/null)"
echo "$err" | grep -q "$note_task" || fail "opencode: no note about the undecided Task in its own tree: $err"
echo "$err" | grep -q '^NOTE: 1 Task' || fail "opencode: the note miscounts pending Tasks: $err"

# A backlog stays visible without dumping every Task id on each invocation.
for n in 1 2 3 4 5 6; do
  synthetic="$stub_dir/state/workflow-skills/subagents/task_00000000-000000-$n"
  mkdir -p "$synthetic"
  jq --arg id "task_00000000-000000-$n" '.task_id = $id' "$(taskdir_of "$note_task")/task.json" >"$synthetic/task.json"
done
err="$(cd "$note_repo" && run_delegate "$oc" list 2>&1 >/dev/null)"
echo "$err" | grep -q '^NOTE: 7 Task' || fail "opencode: backlog note miscounts Tasks: $err"
echo "$err" | grep -q '+4 more; delegate.sh list --active' || fail "opencode: backlog note lacks the lookup command: $err"
[ "$(printf '%s' "$err" | wc -c)" -lt 250 ] || fail "opencode: backlog note prints too many Task ids: $err"
for n in 1 2 3 4 5 6; do
  rm -r "$stub_dir/state/workflow-skills/subagents/task_00000000-000000-$n"
done

err="$(cd "$note_repo" && run_delegate "$oc" status "$note_task" 2>&1 >/dev/null)"
[ -z "$err" ] || fail "opencode: status repeated a backlog note: $err"

# a different tree must not be nagged about it
err="$(cd "$other_repo" && run_delegate "$oc" list 2>&1 >/dev/null)"
echo "$err" | grep -q "$note_task" && fail "opencode: undecided Task leaked into another tree's note: $err"

# and a launch's --json stdout stays parseable while the note is printed
out="$(cd "$note_repo" && run_delegate "$oc" run --json "another task" 2>/dev/null)"
echo "$out" | jq -e '.task_id' >/dev/null || fail "opencode: the note broke --json output: $out"

# once decided, it stops being mentioned
run_delegate "$oc" decide "$note_task" accept --reason "done" >/dev/null
err="$(cd "$note_repo" && run_delegate "$oc" list 2>&1 >/dev/null)"
echo "$err" | grep -q "$note_task" && fail "opencode: a decided Task is still reported as pending: $err"

# --- report rendering -------------------------------------------------------

# a BLOCKED worker's question must survive rendering. Tailing the raw report
# would hide it behind a long CONCERNS list, since QUESTION is second to last.
blocked_task="$(STUB_STATUS=BLOCKED run_delegate "$oc" run --json "blocking task" | jq -r .task_id)"
set +e
res="$(run_delegate "$oc" status "$blocked_task")"
set -e
echo "$res" | grep -q 'QUESTION: ' || fail "opencode: the worker's question is not rendered: $res"
run_delegate "$oc" decide "$blocked_task" accept --reason "fixture" >/dev/null

# --full restores the report verbatim
set +e
res="$(run_delegate "$oc" status "$blocked_task" --full)"
set -e
echo "$res" | grep -q 'STATUS: BLOCKED' || fail "opencode: --full did not restore the raw report: $res"

# a fallback report is raw provider JSONL: a handful of lines, tens of
# kilobytes. A line-count cap alone would print all of it.
long_task="$(run_delegate "$oc" run --json "long report task" | jq -r .task_id)"
long_res="$(taskdir_of "$long_task")/attempts/attempt_001/result.json"
jq --arg r "$(printf 'x%.0s' $(seq 1 9000))" '.report = $r | .worker_verification = null
  | .worker_concerns = null | .worker_question = null' "$long_res" >"$long_res.tmp"
mv "$long_res.tmp" "$long_res"
set +e
res="$(run_delegate "$oc" status "$long_task")"
set -e
[ "$(printf '%s' "$res" | wc -c)" -lt 3000 ] \
  || fail "opencode: a single huge report line was not capped ($(printf '%s' "$res" | wc -c) bytes)"
echo "$res" | grep -q 'truncated to the last 2000 characters' \
  || fail "opencode: byte truncation is not announced: $res"
set +e
res="$(run_delegate "$oc" status "$long_task" --full)"
set -e
[ "$(printf '%s' "$res" | wc -c)" -gt 9000 ] || fail "opencode: --full did not restore the long report"
run_delegate "$oc" decide "$long_task" accept --reason "fixture" >/dev/null

# --json is never truncated, whatever the human view does
res="$(run_delegate "$oc" status "$blocked_task" --json)"
echo "$res" | jq -e '.report | contains("STATUS: BLOCKED")' >/dev/null \
  || fail "opencode: --json must carry the whole report: $res"

# --- legacy state ------------------------------------------------------------

# pre-Task job directories are readable and clearly labelled, never reinterpreted
legacy_dir="$stub_dir/state/workflow-skills/subagents/opencode-20200101-120000"
mkdir -p "$legacy_dir"
echo "done 0" >"$legacy_dir/status"
printf 'SESSION: ses_old\nEXIT: 0\n--- REPORT ---\nold job report\n' >"$legacy_dir/result.txt"
res="$(run_delegate "$oc" status opencode-20200101-120000)"
echo "$res" | grep -q '^LEGACY JOB:' || fail "opencode: legacy job not labelled: $res"
echo "$res" | grep -q 'old job report' || fail "opencode: legacy job report lost: $res"
run_delegate "$oc" status opencode-20200101-120000 --json | jq -e '.legacy == true' >/dev/null \
  || fail "opencode: legacy job not flagged in JSON"
run_delegate "$oc" list --json | jq -e 'map(select(.task_id == "opencode-20200101-120000")) | length == 0' >/dev/null \
  || fail "opencode: legacy job listed as a Task"

# A historical attempt can have a valid final stream but a saved no_report.
# recover restores the worker result without changing an accepted decision.
recovery_task="$(run_delegate "$oc" run --json "recover saved report" | jq -r .task_id)"
recovery_dir="$(taskdir_of "$recovery_task")"
run_delegate "$oc" decide "$recovery_task" accept --reason "fixture accepted" >/dev/null
jq '.worker = "no_report" | .failure_class = "no_final_report" | .recommended_action = "resume_same_session" | .report = "old progress"' \
  "$recovery_dir/attempts/attempt_001/result.json" >"$recovery_dir/attempts/attempt_001/result.json.tmp"
mv "$recovery_dir/attempts/attempt_001/result.json.tmp" "$recovery_dir/attempts/attempt_001/result.json"
jq '.outcome.worker = "no_report" | .failure_class = "no_final_report"' "$recovery_dir/task.json" >"$recovery_dir/task.json.tmp"
mv "$recovery_dir/task.json.tmp" "$recovery_dir/task.json"
run_delegate "$oc" recover --reports-only --json | jq -e --arg id "$recovery_task" \
  'any(.[]; .task_id == $id and (.reconciliation | contains("report_recovered")))' >/dev/null \
  || fail "opencode: recover did not find a saved final stream"
jq -e '.state == "accepted" and .outcome.worker == "done" and .outcome.supervisor == "accepted"' \
  "$recovery_dir/task.json" >/dev/null || fail "opencode: recover changed the supervisor decision"
jq -e '.worker == "done" and (.report | contains("STATUS: DONE"))' \
  "$recovery_dir/attempts/attempt_001/result.json" >/dev/null || fail "opencode: recover lost the final report"
before_events="$(wc -l <"$recovery_dir/events.jsonl")"
# Simulate a crash after result.json was written but before Task and event sync.
jq '.outcome.worker = "no_report"' "$recovery_dir/task.json" >"$recovery_dir/task.json.tmp"
mv "$recovery_dir/task.json.tmp" "$recovery_dir/task.json"
jq -c 'select(.type != "result_recovered")' "$recovery_dir/events.jsonl" >"$recovery_dir/events.jsonl.tmp"
mv "$recovery_dir/events.jsonl.tmp" "$recovery_dir/events.jsonl"
run_delegate "$oc" recover --reports-only --json >/dev/null
jq -e '.state == "accepted" and .outcome.worker == "done"' "$recovery_dir/task.json" >/dev/null \
  || fail "opencode: recover did not finish an interrupted report repair"
[ "$(wc -l <"$recovery_dir/events.jsonl")" -eq "$before_events" ] \
  || fail "opencode: recover did not restore one result_recovered event"
run_delegate "$oc" recover --reports-only --json >/dev/null
[ "$(wc -l <"$recovery_dir/events.jsonl")" -eq "$before_events" ] \
  || fail "opencode: repeated recover duplicated result_recovered"

echo "Subagent script tests passed."
