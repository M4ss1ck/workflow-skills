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

# --- stub: opencode ---------------------------------------------------------
cat >"$stub_dir/opencode" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DIR}/opencode.args"
echo "stub banner noise (must not break JSON parsing)" >&2
cat <<'EOF'
{"type":"step_start","timestamp":1,"sessionID":"ses_oc1","part":{"type":"step-start"}}
{"type":"text","timestamp":2,"sessionID":"ses_oc1","part":{"type":"text","text":"Report: created foo.txt, verification passed"}}
{"type":"step_finish","timestamp":3,"sessionID":"ses_oc1","part":{"type":"step-finish","cost":0.0042,"tokens":{"total":13009,"input":171,"output":27}}}
EOF
STUB
chmod +x "$stub_dir/opencode"

# jq must be real; the stubs replace only the provider CLIs.
command -v jq >/dev/null || fail "these tests require jq on PATH"

run_delegate() {
  local script="$1"
  shift
  STUB_DIR="$stub_dir" PATH="$stub_dir:$PATH" bash "$script" "$@"
}

oc="$repo_root/skills/opencode-subagent/scripts/delegate.sh"

# fresh delegation builds the right command and normalizes output
out="$(run_delegate "$oc" --model anthropic/claude-haiku-4-5 "do the thing")"
grep -q 'run --format json --model anthropic/claude-haiku-4-5 do the thing' "$stub_dir/opencode.args" \
  || fail "opencode: unexpected args: $(cat "$stub_dir/opencode.args")"
echo "$out" | grep -q '^SESSION: ses_oc1$' || fail "opencode: session not extracted: $out"
echo "$out" | grep -q '^COST: 0.0042$' || fail "opencode: cost not extracted: $out"
echo "$out" | grep -q '^EXIT: 0$' || fail "opencode: exit line missing: $out"
echo "$out" | grep -q -- '--- REPORT ---' || fail "opencode: report marker missing: $out"
echo "$out" | grep -q 'verification passed' || fail "opencode: report text missing: $out"

# resume maps to --session
: >"$stub_dir/opencode.args"
run_delegate "$oc" --resume ses_oc1 "fix: rename foo" >/dev/null
grep -q -- '--session ses_oc1 fix: rename foo' "$stub_dir/opencode.args" \
  || fail "opencode: resume did not pass --session: $(cat "$stub_dir/opencode.args")"

# --cwd maps to --dir
: >"$stub_dir/opencode.args"
run_delegate "$oc" --cwd /tmp "task" >/dev/null
grep -q -- '--dir /tmp task' "$stub_dir/opencode.args" \
  || fail "opencode: --cwd did not pass --dir: $(cat "$stub_dir/opencode.args")"

# no --model unless the user asked for one (delegate's configured default applies)
if grep -q -- '--model' "$stub_dir/opencode.args"; then
  fail "opencode: passed --model the user did not request"
fi

# missing spec fails with usage error
if run_delegate "$oc" --model x/y >/dev/null 2>&1; then
  fail "opencode: missing spec should exit nonzero"
fi

# missing CLI fails loudly with 127
set +e
STUB_DIR="$stub_dir" PATH="/usr/bin:/bin" bash "$oc" "task" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 127 ] || fail "opencode: missing CLI should exit 127, got $code"

# --- stub: claude -----------------------------------------------------------
cat >"$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DIR}/claude.args"
echo "stub banner noise (must not break JSON parsing)" >&2
cat <<'EOF'
{"type":"result","subtype":"success","is_error":false,"session_id":"ses_cl1","total_cost_usd":0.0311,"result":"Report: updated bar.py, tests pass"}
EOF
STUB
chmod +x "$stub_dir/claude"

cl="$repo_root/skills/claude-subagent/scripts/delegate.sh"

out="$(run_delegate "$cl" --model claude-haiku-4-5 "do the thing")"
grep -q -- '-p --output-format json --permission-mode acceptEdits --model claude-haiku-4-5 do the thing' "$stub_dir/claude.args" \
  || fail "claude: unexpected args: $(cat "$stub_dir/claude.args")"
echo "$out" | grep -q '^SESSION: ses_cl1$' || fail "claude: session not extracted: $out"
echo "$out" | grep -q '^COST: 0.0311$' || fail "claude: cost not extracted: $out"
echo "$out" | grep -q 'tests pass' || fail "claude: report text missing: $out"

: >"$stub_dir/claude.args"
run_delegate "$cl" --resume ses_cl1 --permission-mode bypassPermissions "fix: typo" >/dev/null
grep -q -- '--permission-mode bypassPermissions --resume ses_cl1 fix: typo' "$stub_dir/claude.args" \
  || fail "claude: resume/permission-mode args wrong: $(cat "$stub_dir/claude.args")"

# no --model unless the user asked for one (delegate's configured default applies)
if grep -q -- '--model' "$stub_dir/claude.args"; then
  fail "claude: passed --model the user did not request"
fi

set +e
STUB_DIR="$stub_dir" PATH="/usr/bin:/bin" bash "$cl" "task" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 127 ] || fail "claude: missing CLI should exit 127, got $code"

# --- stub: codex ------------------------------------------------------------
cat >"$stub_dir/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DIR}/codex.args"
echo "stub banner noise (must not break JSON parsing)" >&2
cat <<'EOF'
{"type":"thread.started","thread_id":"ses_cx1"}
{"type":"item.completed","item":{"type":"agent_message","text":"Report: refactored baz.rs, cargo test passes"}}
{"type":"turn.completed","usage":{"input_tokens":900,"output_tokens":210}}
EOF
STUB
chmod +x "$stub_dir/codex"

cx="$repo_root/skills/codex-subagent/scripts/delegate.sh"

out="$(run_delegate "$cx" --model gpt-5-codex "do the thing")"
grep -q -- 'exec --json -s workspace-write --skip-git-repo-check -m gpt-5-codex do the thing' "$stub_dir/codex.args" \
  || fail "codex: unexpected args: $(cat "$stub_dir/codex.args")"
echo "$out" | grep -q '^SESSION: ses_cx1$' || fail "codex: session not extracted: $out"
echo "$out" | grep -q '^COST: 900 in / 210 out tokens$' || fail "codex: usage not extracted: $out"
echo "$out" | grep -q 'cargo test passes' || fail "codex: report text missing: $out"

: >"$stub_dir/codex.args"
run_delegate "$cx" --resume ses_cx1 "fix: lint" >/dev/null
grep -q -- '--json.*resume ses_cx1 fix: lint' "$stub_dir/codex.args" \
  || fail "codex: resume args wrong: $(cat "$stub_dir/codex.args")"

: >"$stub_dir/codex.args"
run_delegate "$cx" --cwd /tmp "task" >/dev/null
grep -q -- '-C /tmp task' "$stub_dir/codex.args" \
  || fail "codex: --cwd did not pass -C: $(cat "$stub_dir/codex.args")"

# no -m unless the user asked for one (delegate's configured default applies)
if grep -q -- ' -m ' "$stub_dir/codex.args"; then
  fail "codex: passed -m the user did not request"
fi

set +e
STUB_DIR="$stub_dir" PATH="/usr/bin:/bin" bash "$cx" "task" >/dev/null 2>&1
code=$?
set -e
[ "$code" -eq 127 ] || fail "codex: missing CLI should exit 127, got $code"

echo "Subagent script tests passed."
