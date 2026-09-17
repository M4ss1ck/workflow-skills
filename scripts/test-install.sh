#!/usr/bin/env bash
# Validate the local installer against temporary agent homes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
# --doctor runs the real CLIs; opencode keeps writing its cache into the fake
# HOME for a moment after exiting, so retry the cleanup once.
trap 'rm -rf "$tmp_root" 2>/dev/null || { sleep 2; rm -rf "$tmp_root"; }' EXIT
# A space in HOME: every generated path and hook command must survive it.
tmp_home="$tmp_root/home dir"
mkdir -p "$tmp_home"
# Never let a developer's XDG dirs leak the runtime or state out of the sandbox.
export XDG_DATA_HOME="$tmp_home/.local/share"
export XDG_CONFIG_HOME="$tmp_home/.config"
export XDG_STATE_HOME="$tmp_home/.local/state"

fail() { echo "FAIL  $1" >&2; exit 1; }

assert_skill_installed() {
  local target="$1"
  local skill="$2"

  if [ ! -e "$target/$skill/SKILL.md" ]; then
    echo "FAIL  expected $target/$skill/SKILL.md" >&2
    exit 1
  fi
}

HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent codex >/dev/null
assert_skill_installed "$tmp_home/.agents/skills" report-changes

HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent opencode >/dev/null
assert_skill_installed "$tmp_home/.config/opencode/skills" report-changes

# the opencode target also installs agent definitions shipped by skills,
# otherwise `opencode run --agent NAME` falls back to the default agent
worker="$tmp_home/.config/opencode/agent/workflow-worker.md"
[ -e "$worker" ] || { echo "FAIL  expected $worker" >&2; exit 1; }
grep -q '^name: workflow-worker$' "$worker" \
  || { echo "FAIL  $worker is not the worker agent definition" >&2; exit 1; }

HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent gemini >/dev/null
assert_skill_installed "$tmp_home/.gemini/skills" report-changes

HOME="$tmp_home" "$repo_root/scripts/install.sh" --all >/dev/null
assert_skill_installed "$tmp_home/.claude/skills" report-changes
assert_skill_installed "$tmp_home/.agents/skills" report-changes
assert_skill_installed "$tmp_home/.codex/skills" report-changes
assert_skill_installed "$tmp_home/.gemini/skills" report-changes
assert_skill_installed "$tmp_home/.gemini/antigravity/skills" report-changes
assert_skill_installed "$tmp_home/.config/opencode/skills" report-changes

HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent codex --copy >/dev/null
if [ -L "$tmp_home/.agents/skills/report-changes" ]; then
  echo "FAIL  --copy created a symlink" >&2
  exit 1
fi

# the PATH entry is installed and actually RUNS from another cwd — asserting the
# symlink exists would miss the script failing to find its own skill directory
delegate_bin="$tmp_home/.local/bin/opencode-delegate"
[ -L "$delegate_bin" ] || { echo "FAIL  expected $delegate_bin" >&2; exit 1; }
out="$(cd / && HOME="$tmp_home" XDG_CONFIG_HOME="$tmp_home/.config" PATH="$tmp_home/.local/bin:$PATH" opencode-delegate policy 2>&1)" \
  || { echo "FAIL  opencode-delegate on PATH does not run: $out" >&2; exit 1; }
echo "$out" | grep -q '^DELEGATION_POLICY:' \
  || { echo "FAIL  opencode-delegate ran but lost its skill dir: $out" >&2; exit 1; }

# repointing an existing link at a different checkout is announced, not silent
ln -sfn /nonexistent/other/checkout/delegate.sh "$delegate_bin"
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude </dev/null)"
echo "$out" | grep -q 'REPOINTED' || { echo "FAIL  repointing was not announced: $out" >&2; exit 1; }

# --subagent-permissions writes claude allow rules, idempotently
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude --subagent-permissions </dev/null >/dev/null
grep -q 'opencode-subagent/scripts/delegate.sh' "$tmp_home/.claude/settings.json" \
  || { echo "FAIL  claude settings.json missing delegate allow rule" >&2; exit 1; }
# the bare PATH name matches neither the path rule nor the *delegate.sh* glob,
# so it needs its own rule or every delegation starts prompting again
grep -q 'Bash(opencode-delegate:\*)' "$tmp_home/.claude/settings.json" \
  || { echo "FAIL  claude settings.json missing opencode-delegate allow rule" >&2; exit 1; }
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude --subagent-permissions </dev/null >/dev/null
count="$(grep -c 'Bash(bash .*opencode-subagent/scripts/delegate.sh' "$tmp_home/.claude/settings.json")"
if [ "$count" -ne 1 ]; then
  echo "FAIL  claude allow rule duplicated on second run (count=$count)" >&2
  exit 1
fi

# --subagent-permissions enables codex network access, idempotently
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent codex --subagent-permissions </dev/null >/dev/null
grep -q 'network_access = true' "$tmp_home/.codex/config.toml" \
  || { echo "FAIL  codex config.toml missing network_access" >&2; exit 1; }
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent codex --subagent-permissions </dev/null >/dev/null
count="$(grep -c '^\[sandbox_workspace_write\]' "$tmp_home/.codex/config.toml")"
if [ "$count" -ne 1 ]; then
  echo "FAIL  codex sandbox section duplicated (count=$count)" >&2
  exit 1
fi

# --subagent-permissions writes opencode bash permission, idempotently
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent opencode --subagent-permissions </dev/null >/dev/null
grep -q 'delegate.sh' "$tmp_home/.config/opencode/opencode.json" \
  || { echo "FAIL  opencode.json missing delegate.sh permission" >&2; exit 1; }
grep -q 'opencode-delegate' "$tmp_home/.config/opencode/opencode.json" \
  || { echo "FAIL  opencode.json missing opencode-delegate permission" >&2; exit 1; }

# without the flag and without a TTY, no permissions are written
rm -rf "$tmp_home/.claude/settings.json"
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude </dev/null >/dev/null
if grep -q '"permissions"' "$tmp_home/.claude/settings.json" 2>/dev/null; then
  echo "FAIL  permissions written without consent" >&2
  exit 1
fi

# --doctor reports the worker agent install state
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --doctor)"
echo "$out" | grep -q 'worker' || { echo "FAIL  --doctor missing worker agent line" >&2; exit 1; }

# --doctor reports on the three CLIs and jq
out="$("$repo_root/scripts/install.sh" --doctor)"
for tool in claude codex opencode jq; do
  echo "$out" | grep -q "$tool" || { echo "FAIL  --doctor missing $tool" >&2; exit 1; }
done

# --doctor reports the subagent model conf
mkdir -p "$tmp_home/.config/workflow-skills"
echo 'OPENCODE_SUBAGENT_MODEL=stub/model' >"$tmp_home/.config/workflow-skills/subagents.conf"
out="$(XDG_CONFIG_HOME="$tmp_home/.config" HOME="$tmp_home" "$repo_root/scripts/install.sh" --doctor)"
echo "$out" | grep -q 'stub/model' || { echo "FAIL  --doctor missing conf contents" >&2; exit 1; }

# ---------------------------------------------------------------- routing hooks

agent_payload='{"hook_event_name":"PreToolUse","session_id":"t","cwd":"/","tool_name":"Agent","tool_input":{"prompt":"x"}}'
settings="$tmp_home/.claude/settings.json"

hook_commands() {  # the owned hook commands in a settings/hooks file, one per line
  python3 - "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for groups in data.get("hooks", {}).values():
    for group in groups:
        for h in group["hooks"]:
            if "workflow-skills-routing" in h["command"]:
                print(h["command"])
PY
}

# run a hook command the way a host does: sh -c, from /, with a PATH that has
# only the system directories: no ~/.local/bin, no conda/pyenv python
run_hook_command() {
  env -i HOME="$tmp_home" PATH="/usr/bin:/bin" XDG_STATE_HOME="$XDG_STATE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    /bin/sh -c "cd / && $1" <<<"$agent_payload"
}

# claude: hooks are merged next to unrelated settings and hooks, idempotently
rm -rf "$settings" "$XDG_DATA_HOME"
mkdir -p "$(dirname "$settings")"
cat >"$settings" <<'JSON'
{"model": "keep-me", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo unrelated"}]}]}}
JSON
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude </dev/null)"
echo "$out" | grep -q 'new Claude Code session' || fail "claude hook install did not print reload steps: $out"
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude </dev/null >/dev/null
[ "$(hook_commands "$settings" | wc -l)" -eq 3 ] || fail "expected 3 owned claude hook entries after rerun: $(hook_commands "$settings")"
grep -q 'echo unrelated' "$settings" || fail "unrelated claude hook was lost"
grep -q '"keep-me"' "$settings" || fail "unrelated claude setting was lost"
python3 -c "import json,re,sys; d=json.load(open(sys.argv[1])); m=[g['matcher'] for g in d['hooks']['PreToolUse'] if 'matcher' in g and 'workflow' in g['hooks'][0]['command']]; assert m and re.search(m[0],'Agent'), m" "$settings" \
  || fail "claude PreToolUse matcher missing"

# the registered command runs without PATH help and denies an unrecorded Agent call
cmd="$(hook_commands "$settings" | head -1)"
echo "$cmd" | grep -q "$repo_root/skills/opencode-subagent/scripts/delegate.sh" || fail "symlink-mode hook does not use the checkout: $cmd"
out="$(run_hook_command "$cmd")"
echo "$out" | grep -q '"permissionDecision": "deny"' || fail "installed claude hook did not deny: $out"

# the checkout switching to a branch without routing must not block prompts:
# delegation calls are denied, every other event passes with exit 0 and no output
cp -R "$repo_root/skills/opencode-subagent" "$tmp_root/old-skill"
git -C "$repo_root" show 333bcad:skills/opencode-subagent/scripts/delegate.sh >"$tmp_root/old-skill/scripts/delegate.sh"
rm -f "$tmp_root/old-skill/scripts/routing.py"
old_cmd="${cmd//$repo_root\/skills\/opencode-subagent/$tmp_root/old-skill}"
[ "$old_cmd" != "$cmd" ] || fail "could not retarget the hook command at an old checkout"
out="$(run_hook_command "$old_cmd")" || fail "hook command exited non-zero against an old checkout"
echo "$out" | grep -q '"permissionDecision":"deny"' || fail "old checkout did not deny a delegation call: $out"
set +e
out="$(env -i HOME="$tmp_home" PATH="/usr/bin:/bin" /bin/sh -c "cd / && $old_cmd" <<<'{"hook_event_name":"UserPromptSubmit","session_id":"t","prompt":"hi"}')"
status=$?
set -e
[ "$status" -eq 0 ] && [ -z "$out" ] || fail "old checkout blocked a user prompt (exit $status): $out"
rm -rf "$tmp_root/old-skill/scripts/delegate.sh"
out="$(run_hook_command "$old_cmd")" || fail "hook command exited non-zero with the entry missing"
echo "$out" | grep -q '"permissionDecision":"deny"' || fail "missing entry did not deny: $out"

# a symlinked settings.json (dotfiles) is edited through the link, keeping its mode
dotfiles="$tmp_root/dotfiles"
mkdir -p "$dotfiles"
echo '{"model": "linked"}' >"$dotfiles/settings.json"
chmod 640 "$dotfiles/settings.json"
mv "$settings" "$tmp_root/settings.backup.json"
ln -s "$dotfiles/settings.json" "$settings"
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude </dev/null >/dev/null
[ -L "$settings" ] || fail "symlinked settings.json was replaced by a regular file"
[ "$(hook_commands "$dotfiles/settings.json" | wc -l)" -eq 3 ] || fail "hooks not written through the settings symlink"
[ "$(stat -c %a "$dotfiles/settings.json")" = 640 ] || fail "settings.json mode changed: $(stat -c %a "$dotfiles/settings.json")"
rm "$settings"
mv "$tmp_root/settings.backup.json" "$settings"

# removal takes only owned entries
HOME="$tmp_home" "$repo_root/scripts/install.sh" --remove-hooks --agent claude </dev/null >/dev/null
[ -z "$(hook_commands "$settings")" ] || fail "--remove-hooks left owned entries"
grep -q 'echo unrelated' "$settings" || fail "--remove-hooks removed an unrelated hook"
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --remove-hooks --agent claude </dev/null)"
echo "$out" | grep -q 'nothing to remove' || fail "second --remove-hooks was not a no-op: $out"

# --no-hooks skips registration and says so
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude --no-hooks </dev/null)"
echo "$out" | grep -q 'skipped (--no-hooks)' || fail "--no-hooks not reported: $out"
[ -z "$(hook_commands "$settings")" ] || fail "--no-hooks registered hooks"

# a generic target reports enforcement as unavailable
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --dir "$tmp_root/custom skills" </dev/null)"
echo "$out" | grep -q 'not available for these targets' || fail "--dir did not report enforcement unavailable: $out"

# an installed workflow-skills plugin already ships the hooks: no duplicate
mkdir -p "$tmp_home/.claude/plugins"
echo '{"version":2,"plugins":{"workflow-skills@workflow-skills":[{"installPath":"/x"}]}}' >"$tmp_home/.claude/plugins/installed_plugins.json"
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude </dev/null)"
echo "$out" | grep -q 'not adding a duplicate' || fail "plugin registration not detected: $out"
mkdir -p "$tmp_home/.codex"
printf '[plugins."workflow-skills@local"]\nenabled = true\n' >"$tmp_home/.codex/config.toml"
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent codex </dev/null 2>&1)"
echo "$out" | grep -q 'not verified on Codex' || fail "codex plugin hooks not flagged as unverified: $out"
rm -f "$tmp_home/.codex/config.toml"
[ -z "$(hook_commands "$settings")" ] || fail "hooks duplicated next to the plugin"
rm -rf "$tmp_home/.claude/plugins"

# codex: hooks.json gets the entries and the trust step is printed
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent codex </dev/null)"
echo "$out" | grep -q 'trust' || fail "codex trust step not printed: $out"
[ "$(hook_commands "$tmp_home/.codex/hooks.json" | wc -l)" -eq 3 ] || fail "expected 3 codex hook entries"
hook_commands "$tmp_home/.codex/hooks.json" | head -1 | grep -q -- 'delegate.sh codex # workflow-skills-routing' || fail "codex hook does not pass host codex"

# no python3: hooks are reported as not installed instead of half-written
nopy="$tmp_root/nopython"
mkdir -p "$nopy"
for tool in bash sh dirname basename mkdir ln rm cp mv readlink grep sed cat head wc env; do
  src="$(command -v "$tool" || true)"
  [ -n "$src" ] && ln -sf "$src" "$nopy/$tool"
done
rm -rf "$tmp_home/.codex/hooks.json"
out="$(HOME="$tmp_home" PATH="$nopy" "$nopy/bash" "$repo_root/scripts/install.sh" --agent codex </dev/null 2>&1)"
echo "$out" | grep -q 'NOT installed: python3 is required' || fail "missing python3 not reported: $out"
[ ! -e "$tmp_home/.codex/hooks.json" ] || fail "hooks written without python3"

# copy mode: one owned runtime that survives the checkout disappearing
checkout="$tmp_root/checkout copy"
mkdir -p "$checkout"
cp -R "$repo_root/scripts" "$repo_root/skills" "$repo_root/hooks" "$checkout/"
rm -rf "$XDG_DATA_HOME" "$settings"
HOME="$tmp_home" "$checkout/scripts/install.sh" --agent claude --copy </dev/null >/dev/null
runtime="$XDG_DATA_HOME/workflow-skills/opencode-subagent"
[ -f "$runtime/.installed-by-workflow-skills" ] || fail "copy mode did not install the owned runtime"
[ "$(readlink "$tmp_home/.local/bin/opencode-delegate")" = "$runtime/scripts/delegate.sh" ] \
  || fail "copy-mode PATH command does not point at the runtime: $(readlink "$tmp_home/.local/bin/opencode-delegate")"
rm -rf "$checkout"
out="$(cd / && HOME="$tmp_home" PATH="$tmp_home/.local/bin:$PATH" opencode-delegate route identity)" \
  || fail "copy-mode PATH command broke after removing the checkout: $out"
echo "$out" | grep -q "$runtime/scripts/routing.py" || fail "copy-mode identity is not the runtime: $out"
out="$(run_hook_command "$(hook_commands "$settings" | head -1)")"
echo "$out" | grep -q '"permissionDecision": "deny"' || fail "copy-mode hook broke after removing the checkout: $out"

# rerunning copy mode replaces the owned runtime; an unowned directory is never overwritten
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude --copy </dev/null >/dev/null
rm -rf "$runtime" "$settings" "$tmp_home/.local/bin/opencode-delegate"
mkdir -p "$runtime" && echo mine >"$runtime/keep.txt"
out="$(HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude --copy </dev/null 2>&1)"
echo "$out" | grep -q 'was not installed by workflow-skills' || fail "unowned runtime conflict not reported: $out"
[ -f "$runtime/keep.txt" ] || fail "unowned runtime directory was overwritten"
[ ! -e "$tmp_home/.local/bin/opencode-delegate" ] || fail "PATH command installed despite runtime conflict"
[ -z "$(hook_commands "$settings" 2>/dev/null)" ] || fail "hooks installed despite runtime conflict"
rm -rf "$runtime"

echo "Installer tests passed."
