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
  STUB_DB_FAIL="${STUB_DB_FAIL:-0}" \
  STUB_FINISH_DRIFT="${STUB_FINISH_DRIFT:-0}" \
  XDG_STATE_HOME="$stub_dir/state" \
  XDG_CONFIG_HOME="$stub_dir/config" \
  DELEGATE_POLL_INTERVAL=1 \
  PATH="$stub_dir:$PATH" bash "$script" "$@"
}

job_of() { echo "$1" | sed -n 's/^JOB: //p'; }
jobdir_of() { echo "$stub_dir/state/workflow-skills/subagents/$1"; }
conf_file="$stub_dir/config/workflow-skills/subagents.conf"

# Launch, then wait to completion; prints the wait output.
launch_and_wait() {
  local script="$1"
  shift
  local out job
  out="$(run_delegate "$script" "$@")"
  job="$(job_of "$out")"
  run_delegate "$script" --wait "$job" --poll-timeout 30
}

# --- stub: opencode ---------------------------------------------------------
cat >"$stub_dir/opencode" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DIR}/opencode.args"
if [ "${1:-}" = "db" ]; then
  if [ "${2:-}" = "path" ]; then
    : >"${STUB_DIR}/opencode.db"
    echo "${STUB_DIR}/opencode.db"
    exit 0
  fi
  printf '%s\n' "${2:-}" >>"${STUB_DIR}/opencode-db.sql"
  if [ "${STUB_DB_FAIL:-0}" = "1" ]; then
    echo 'stub database failure' >&2
    exit 1
  fi
  case "${2:-}" in
    *"json_extract(data, '$.finish') = 'stop'"*)
      if [ "${STUB_NO_FINAL:-0}" = "1" ] || [ "${STUB_FINISH_DRIFT:-0}" = "1" ] || [ ! -s "${STUB_DIR}/opencode-final.id" ]; then
        echo '[]'
      else
        printf '[{"id":"%s"}]\n' "$(cat "${STUB_DIR}/opencode-final.id")"
      fi
      ;;
    *"SELECT id FROM message"*)
      if [ -s "${STUB_DIR}/opencode-assistant.id" ]; then
        printf '[{"id":"%s"}]\n' "$(cat "${STUB_DIR}/opencode-assistant.id")"
      else
        echo '[]'
      fi
      ;;
    *"AS finish FROM message"*)
      if [ "${STUB_FINISH_DRIFT:-0}" = "1" ]; then
        echo '[{"finish":"completed"}]'
      elif [ "${STUB_NO_FINAL:-0}" = "1" ]; then
        echo '[{"finish":null}]'
      else
        echo '[{"finish":"stop"}]'
      fi
      ;;
    *"SELECT json_extract(data, '$.text') AS text"*)
      echo '[{"text":"Report: provider final verification passed"}]'
      ;;
    *"SELECT COALESCE(SUM"*)
      echo '[{"cost":0.0042}]'
      ;;
    *"SELECT time_created, message_id"*)
      echo '[{"time_created":2,"message_id":"msg_oc_final","type":"text","tool":null,"status":null,"text":"provider final verification passed"}]'
      ;;
    *)
      echo '[]'
      ;;
  esac
  exit 0
fi
echo "stub banner noise (must stay out of raw.jsonl)" >&2
turn="$$-$RANDOM"
rm -f "${STUB_DIR}/opencode-final.id"
printf 'msg_oc_assistant_%s\n' "$turn" >"${STUB_DIR}/opencode-assistant.id"
cat <<'EOF'
{"type":"step_start","timestamp":1,"sessionID":"ses_oc1","part":{"type":"step-start"}}
EOF
if { [ "${STUB_RESUME_HANG:-0}" = "1" ] && [[ " $* " == *" --session "* ]]; } \
  || { [ "${STUB_FRESH_HANG:-0}" = "1" ] && [[ " $* " != *" --session "* ]]; }; then
  printf 'msg_oc_final_%s\n' "$turn" >"${STUB_DIR}/opencode-final.id"
  sleep 30
  exit 0
fi
sleep "${STUB_SLEEP:-0}"
if [ "${STUB_NO_FINAL:-0}" != "1" ]; then
  printf 'msg_oc_final_%s\n' "$turn" >"${STUB_DIR}/opencode-final.id"
fi
cat <<'EOF'
{"type":"text","timestamp":2,"sessionID":"ses_oc1","part":{"type":"text","text":"Report: created foo.txt, verification passed"}}
{"type":"step_finish","timestamp":3,"sessionID":"ses_oc1","part":{"type":"step-finish","cost":0.0042,"tokens":{"total":13009,"input":171,"output":27}}}
EOF
STUB
chmod +x "$stub_dir/opencode"

oc="$repo_root/skills/opencode-subagent/scripts/delegate.sh"

# launch returns immediately and prints the job block
out="$(run_delegate "$oc" --model anthropic/claude-haiku-4-5 "do the thing")"
echo "$out" | grep -q '^JOB: opencode-' || fail "opencode: no JOB line: $out"
echo "$out" | grep -q '^WATCH:' || fail "opencode: no WATCH line: $out"
echo "$out" | grep -q '^STATUS:' || fail "opencode: no STATUS line: $out"
echo "$out" | grep -q '^PROGRESS:' || fail "opencode: no PROGRESS line: $out"
echo "$out" | grep -q '^PROVIDER_REPORT:' || fail "opencode: no PROVIDER_REPORT line: $out"
echo "$out" | grep -q '^RESULT:' || fail "opencode: no RESULT line: $out"
job="$(job_of "$out")"

# wait returns the normalized result once the job finishes, exit 0
res="$(run_delegate "$oc" --wait "$job" --poll-timeout 30)"
grep -q 'run --format json --model anthropic/claude-haiku-4-5 do the thing' "$stub_dir/opencode.args" \
  || fail "opencode: unexpected args: $(cat "$stub_dir/opencode.args")"
echo "$res" | grep -q '^SESSION: ses_oc1$' || fail "opencode: session not extracted: $res"
echo "$res" | grep -q '^COST: 0.0042$' || fail "opencode: cost not extracted: $res"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: exit line missing: $res"
echo "$res" | grep -q -- '--- REPORT ---' || fail "opencode: report marker missing: $res"
echo "$res" | grep -q 'verification passed' || fail "opencode: report text missing: $res"

# stderr is kept out of the JSON stream
jd="$(jobdir_of "$job")"
grep -q 'banner noise' "$jd/stderr.log" || fail "opencode: stderr.log missing stub noise"
jq -s empty "$jd/raw.jsonl" || fail "opencode: raw.jsonl contaminated (not clean JSONL)"
grep -q 'provider final verification passed' "$jd/provider-report.txt" \
  || fail "opencode: provider report file missing final response"

# a still-running job polls out with exit 3 and RUNNING + watch commands
: >"$stub_dir/opencode.args"
out="$(STUB_SLEEP=4 run_delegate "$oc" "slow task")"
job="$(job_of "$out")"
set +e
res="$(run_delegate "$oc" --wait "$job" --poll-timeout 1)"
code=$?
set -e
[ "$code" -eq 3 ] || fail "opencode: running wait should exit 3, got $code"
echo "$res" | grep -q '^RUNNING' || fail "opencode: no RUNNING line: $res"
echo "$res" | grep -q '^WATCH:' || fail "opencode: running wait should reprint WATCH: $res"
for _ in 1 2 3; do
  if grep -q 'provider final verification passed' "$(jobdir_of "$job")/provider-progress.json"; then break; fi
  sleep 1
done
grep -q 'provider final verification passed' "$(jobdir_of "$job")/provider-progress.json" \
  || fail "opencode: fresh-run provider progress stayed empty"
res="$(run_delegate "$oc" --wait "$job" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: slow job did not finish clean: $res"

# the hard timeout kills the job and records status=timeout
out="$(STUB_SLEEP=30 run_delegate "$oc" --timeout 1 "never finishes")"
job="$(job_of "$out")"
set +e
run_delegate "$oc" --wait "$job" --poll-timeout 30 >/dev/null
code=$?
set -e
[ "$code" -eq 124 ] || fail "opencode: timeout should surface exit 124, got $code"
grep -q '^timeout 124' "$(jobdir_of "$job")/status" || fail "opencode: status not marked timeout"

# conf default applies when the user names no model
mkdir -p "$(dirname "$conf_file")"
echo 'OPENCODE_SUBAGENT_MODEL=stub/conf-model' >"$conf_file"
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

# no model named and no conf -> no --model flag at all
rm -f "$conf_file"
: >"$stub_dir/opencode.args"
launch_and_wait "$oc" "plain task" >/dev/null
if grep -q -- '--model' "$stub_dir/opencode.args"; then
  fail "opencode: passed --model the user did not request"
fi

# resume maps to --session
: >"$stub_dir/opencode.args"
launch_and_wait "$oc" --resume ses_oc1 "fix: rename foo" >/dev/null
grep -q -- '--session ses_oc1 fix: rename foo' "$stub_dir/opencode.args" \
  || fail "opencode: resume did not pass --session: $(cat "$stub_dir/opencode.args")"

# a provider-final response completes a resume even when the CLI event stream hangs
: >"$stub_dir/opencode.args"
out="$(STUB_RESUME_HANG=1 run_delegate "$oc" --resume ses_oc1 "fix: hung stream")"
job="$(job_of "$out")"
res="$(run_delegate "$oc" --wait "$job" --poll-timeout 30)"
echo "$res" | grep -q '^SESSION: ses_oc1$' || fail "opencode: recovered resume session missing: $res"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: provider-complete resume did not finish cleanly: $res"
grep -q 'provider final verification passed' "$(jobdir_of "$job")/provider-report.txt" \
  || fail "opencode: recovered resume provider report missing"

# the same provider-final detection protects a fresh run with a hung event stream
out="$(STUB_FRESH_HANG=1 run_delegate "$oc" "hung fresh stream")"
job="$(job_of "$out")"
res="$(run_delegate "$oc" --wait "$job" --poll-timeout 10)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: provider-complete fresh run did not finish cleanly: $res"

# exit 0 without a provider-final response is incomplete, not successful
out="$(STUB_NO_FINAL=1 run_delegate "$oc" "incomplete task")"
job="$(job_of "$out")"
set +e
res="$(STUB_NO_FINAL=1 run_delegate "$oc" --wait "$job" --poll-timeout 30)"
code=$?
set -e
[ "$code" -eq 4 ] || fail "opencode: incomplete provider turn should exit 4, got $code"
grep -q '^incomplete 4' "$(jobdir_of "$job")/status" || fail "opencode: incomplete turn not marked incomplete"
echo "$res" | grep -q 'before producing a provider-final response' \
  || fail "opencode: incomplete turn lacks actionable report: $res"

# database query failures fall back to CLI output and still finalize job state
out="$(STUB_DB_FAIL=1 run_delegate "$oc" "db fallback")"
job="$(job_of "$out")"
res="$(run_delegate "$oc" --wait "$job" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: DB failure replaced successful CLI exit: $res"
echo "$res" | grep -q 'created foo.txt' || fail "opencode: DB failure lost CLI report: $res"
grep -q '^done 0' "$(jobdir_of "$job")/status" || fail "opencode: DB failure stranded running status"

# an unknown provider finish value is schema drift, not proof of incompleteness
out="$(STUB_FINISH_DRIFT=1 run_delegate "$oc" "finish drift")"
job="$(job_of "$out")"
res="$(run_delegate "$oc" --wait "$job" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "opencode: finish-state drift caused false exit 4: $res"

# SQL literals quote resume ids instead of allowing cross-session predicates
: >"$stub_dir/opencode-db.sql"
launch_and_wait "$oc" --resume "abc' OR '1'='1" "quote session" >/dev/null
grep -Fq "session_id='abc'' OR ''1''=''1'" "$stub_dir/opencode-db.sql" \
  || fail "opencode: resume session was not SQL-quoted"

# --cwd maps to --dir
: >"$stub_dir/opencode.args"
launch_and_wait "$oc" --cwd /tmp "task" >/dev/null
grep -q -- '--dir /tmp task' "$stub_dir/opencode.args" \
  || fail "opencode: --cwd did not pass --dir: $(cat "$stub_dir/opencode.args")"

# --save-default without --model is a usage error
if run_delegate "$oc" --save-default "task" >/dev/null 2>&1; then
  fail "opencode: --save-default without --model should exit nonzero"
fi

# missing spec fails with usage error
if run_delegate "$oc" --model x/y >/dev/null 2>&1; then
  fail "opencode: missing spec should exit nonzero"
fi

# waiting on an unknown job fails with exit 2
set +e
run_delegate "$oc" --wait no-such-job >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 2 ] || fail "opencode: unknown job should exit 2, got $code"

# missing CLI fails loudly with 127 and points at --doctor
set +e
msg="$(STUB_DIR="$stub_dir" PATH="/usr/bin:/bin" bash "$oc" "task" 2>&1)"
code=$?
set -e
[ "$code" -eq 127 ] || fail "opencode: missing CLI should exit 127, got $code"
echo "$msg" | grep -q 'doctor' || fail "opencode: missing-CLI error should mention --doctor: $msg"

# --- stub: claude -----------------------------------------------------------
cat >"$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DIR}/claude.args"
echo "stub banner noise (must stay out of raw.jsonl)" >&2
sleep "${STUB_SLEEP:-0}"
cat <<'EOF'
{"type":"system","subtype":"init","session_id":"ses_cl1"}
{"type":"assistant","session_id":"ses_cl1","message":{"content":[{"type":"text","text":"working on it"}]}}
{"type":"result","subtype":"success","is_error":false,"session_id":"ses_cl1","total_cost_usd":0.0311,"result":"Report: updated bar.py, tests pass"}
EOF
STUB
chmod +x "$stub_dir/claude"

cl="$repo_root/skills/claude-subagent/scripts/delegate.sh"

# launch prints the job block; wait returns the normalized result
out="$(run_delegate "$cl" --model claude-haiku-4-5 "do the thing")"
echo "$out" | grep -q '^JOB: claude-' || fail "claude: no JOB line: $out"
echo "$out" | grep -q '^WATCH:' || fail "claude: no WATCH line: $out"
echo "$out" | grep -q '^PROGRESS:' || fail "claude: no PROGRESS line: $out"
echo "$out" | grep -q '^PROVIDER_REPORT:' || fail "claude: no PROVIDER_REPORT line: $out"
job="$(job_of "$out")"
res="$(run_delegate "$cl" --wait "$job" --poll-timeout 30)"
grep -q -- '-p --output-format stream-json --verbose --permission-mode acceptEdits --model claude-haiku-4-5 do the thing' "$stub_dir/claude.args" \
  || fail "claude: unexpected args: $(cat "$stub_dir/claude.args")"
echo "$res" | grep -q '^SESSION: ses_cl1$' || fail "claude: session not extracted: $res"
echo "$res" | grep -q '^COST: 0.0311$' || fail "claude: cost not extracted: $res"
echo "$res" | grep -q 'tests pass' || fail "claude: report text missing: $res"

# stderr is kept out of the JSON stream
jd="$(jobdir_of "$job")"
grep -q 'banner noise' "$jd/stderr.log" || fail "claude: stderr.log missing stub noise"
jq -s empty "$jd/raw.jsonl" || fail "claude: raw.jsonl contaminated (not clean JSONL)"
grep -q 'tests pass' "$jd/provider-report.txt" || fail "claude: provider report file missing final response"

# a still-running job polls out with exit 3
out="$(STUB_SLEEP=4 run_delegate "$cl" "slow task")"
job="$(job_of "$out")"
set +e
res="$(run_delegate "$cl" --wait "$job" --poll-timeout 1)"
code=$?
set -e
[ "$code" -eq 3 ] || fail "claude: running wait should exit 3, got $code"
echo "$res" | grep -q '^RUNNING' || fail "claude: no RUNNING line: $res"
res="$(run_delegate "$cl" --wait "$job" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "claude: slow job did not finish clean: $res"

# the hard timeout records status=timeout
out="$(STUB_SLEEP=30 run_delegate "$cl" --timeout 1 "never finishes")"
job="$(job_of "$out")"
set +e
run_delegate "$cl" --wait "$job" --poll-timeout 30 >/dev/null
code=$?
set -e
[ "$code" -eq 124 ] || fail "claude: timeout should surface exit 124, got $code"

# conf default / explicit model / save-default / no-model
mkdir -p "$(dirname "$conf_file")"
echo 'CLAUDE_SUBAGENT_MODEL=conf-claude-model' >"$conf_file"
: >"$stub_dir/claude.args"
launch_and_wait "$cl" "conf task" >/dev/null
grep -q -- '--model conf-claude-model' "$stub_dir/claude.args" \
  || fail "claude: conf default not applied: $(cat "$stub_dir/claude.args")"
: >"$stub_dir/claude.args"
launch_and_wait "$cl" --model explicit-claude "task" >/dev/null
grep -q -- '--model explicit-claude' "$stub_dir/claude.args" \
  || fail "claude: explicit model not passed: $(cat "$stub_dir/claude.args")"
launch_and_wait "$cl" --model saved-claude --save-default "task" >/dev/null
grep -q '^CLAUDE_SUBAGENT_MODEL=saved-claude$' "$conf_file" || fail "claude: --save-default not written"
rm -f "$conf_file"
: >"$stub_dir/claude.args"
launch_and_wait "$cl" "plain task" >/dev/null
if grep -q -- '--model' "$stub_dir/claude.args"; then
  fail "claude: passed --model the user did not request"
fi

# resume + permission-mode pass through
: >"$stub_dir/claude.args"
launch_and_wait "$cl" --resume ses_cl1 --permission-mode bypassPermissions "fix: typo" >/dev/null
grep -q -- '--permission-mode bypassPermissions --resume ses_cl1 fix: typo' "$stub_dir/claude.args" \
  || fail "claude: resume/permission-mode args wrong: $(cat "$stub_dir/claude.args")"

# missing spec / missing CLI
if run_delegate "$cl" --model x >/dev/null 2>&1; then
  fail "claude: missing spec should exit nonzero"
fi
set +e
msg="$(STUB_DIR="$stub_dir" PATH="/usr/bin:/bin" bash "$cl" "task" 2>&1)"
code=$?
set -e
[ "$code" -eq 127 ] || fail "claude: missing CLI should exit 127, got $code"
echo "$msg" | grep -q 'doctor' || fail "claude: missing-CLI error should mention --doctor: $msg"

# --- stub: codex ------------------------------------------------------------
cat >"$stub_dir/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DIR}/codex.args"
echo "stub banner noise (must stay out of raw.jsonl)" >&2
sleep "${STUB_SLEEP:-0}"
cat <<'EOF'
{"type":"thread.started","thread_id":"ses_cx1"}
{"type":"item.completed","item":{"type":"agent_message","text":"Report: refactored baz.rs, cargo test passes"}}
{"type":"turn.completed","usage":{"input_tokens":900,"output_tokens":210}}
EOF
STUB
chmod +x "$stub_dir/codex"

cx="$repo_root/skills/codex-subagent/scripts/delegate.sh"

# launch prints the job block; wait returns the normalized result
out="$(run_delegate "$cx" --model gpt-5-codex "do the thing")"
echo "$out" | grep -q '^JOB: codex-' || fail "codex: no JOB line: $out"
echo "$out" | grep -q '^WATCH:' || fail "codex: no WATCH line: $out"
echo "$out" | grep -q '^PROGRESS:' || fail "codex: no PROGRESS line: $out"
echo "$out" | grep -q '^PROVIDER_REPORT:' || fail "codex: no PROVIDER_REPORT line: $out"
job="$(job_of "$out")"
res="$(run_delegate "$cx" --wait "$job" --poll-timeout 30)"
grep -q -- 'exec --json -s workspace-write --skip-git-repo-check -m gpt-5-codex do the thing' "$stub_dir/codex.args" \
  || fail "codex: unexpected args: $(cat "$stub_dir/codex.args")"
echo "$res" | grep -q '^SESSION: ses_cx1$' || fail "codex: session not extracted: $res"
echo "$res" | grep -q '^COST: 900 in / 210 out tokens$' || fail "codex: usage not extracted: $res"
echo "$res" | grep -q 'cargo test passes' || fail "codex: report text missing: $res"

# stderr is kept out of the JSON stream
jd="$(jobdir_of "$job")"
grep -q 'banner noise' "$jd/stderr.log" || fail "codex: stderr.log missing stub noise"
jq -s empty "$jd/raw.jsonl" || fail "codex: raw.jsonl contaminated (not clean JSONL)"
grep -q 'cargo test passes' "$jd/provider-report.txt" || fail "codex: provider report file missing final response"

# a still-running job polls out with exit 3
out="$(STUB_SLEEP=4 run_delegate "$cx" "slow task")"
job="$(job_of "$out")"
set +e
res="$(run_delegate "$cx" --wait "$job" --poll-timeout 1)"
code=$?
set -e
[ "$code" -eq 3 ] || fail "codex: running wait should exit 3, got $code"
echo "$res" | grep -q '^RUNNING' || fail "codex: no RUNNING line: $res"
res="$(run_delegate "$cx" --wait "$job" --poll-timeout 30)"
echo "$res" | grep -q '^EXIT: 0$' || fail "codex: slow job did not finish clean: $res"

# the hard timeout records status=timeout
out="$(STUB_SLEEP=30 run_delegate "$cx" --timeout 1 "never finishes")"
job="$(job_of "$out")"
set +e
run_delegate "$cx" --wait "$job" --poll-timeout 30 >/dev/null
code=$?
set -e
[ "$code" -eq 124 ] || fail "codex: timeout should surface exit 124, got $code"

# conf default / explicit model / save-default / no-model
mkdir -p "$(dirname "$conf_file")"
echo 'CODEX_SUBAGENT_MODEL=conf-codex-model' >"$conf_file"
: >"$stub_dir/codex.args"
launch_and_wait "$cx" "conf task" >/dev/null
grep -q -- '-m conf-codex-model' "$stub_dir/codex.args" \
  || fail "codex: conf default not applied: $(cat "$stub_dir/codex.args")"
: >"$stub_dir/codex.args"
launch_and_wait "$cx" --model explicit-codex "task" >/dev/null
grep -q -- '-m explicit-codex' "$stub_dir/codex.args" \
  || fail "codex: explicit model not passed: $(cat "$stub_dir/codex.args")"
launch_and_wait "$cx" --model saved-codex --save-default "task" >/dev/null
grep -q '^CODEX_SUBAGENT_MODEL=saved-codex$' "$conf_file" || fail "codex: --save-default not written"
rm -f "$conf_file"
: >"$stub_dir/codex.args"
launch_and_wait "$cx" "plain task" >/dev/null
if grep -q -- ' -m ' "$stub_dir/codex.args"; then
  fail "codex: passed -m the user did not request"
fi

# resume maps to exec resume (and drops the fresh-run sandbox flags)
: >"$stub_dir/codex.args"
launch_and_wait "$cx" --resume ses_cx1 "fix: lint" >/dev/null
grep -q -- '--json.*resume ses_cx1 fix: lint' "$stub_dir/codex.args" \
  || fail "codex: resume args wrong: $(cat "$stub_dir/codex.args")"

# --cwd maps to -C
: >"$stub_dir/codex.args"
launch_and_wait "$cx" --cwd /tmp "task" >/dev/null
grep -q -- '-C /tmp task' "$stub_dir/codex.args" \
  || fail "codex: --cwd did not pass -C: $(cat "$stub_dir/codex.args")"

# missing spec / missing CLI
if run_delegate "$cx" --model x >/dev/null 2>&1; then
  fail "codex: missing spec should exit nonzero"
fi
set +e
msg="$(STUB_DIR="$stub_dir" PATH="/usr/bin:/bin" bash "$cx" "task" 2>&1)"
code=$?
set -e
[ "$code" -eq 127 ] || fail "codex: missing CLI should exit 127, got $code"
echo "$msg" | grep -q 'doctor' || fail "codex: missing-CLI error should mention --doctor: $msg"

echo "Subagent script tests passed."
