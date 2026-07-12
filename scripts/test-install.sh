#!/usr/bin/env bash
# Validate the local installer against temporary agent homes.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

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

# --subagent-permissions writes claude allow rules, idempotently
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude --subagent-permissions </dev/null >/dev/null
grep -q 'opencode-subagent/scripts/delegate.sh' "$tmp_home/.claude/settings.json" \
  || { echo "FAIL  claude settings.json missing delegate allow rule" >&2; exit 1; }
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude --subagent-permissions </dev/null >/dev/null
count="$(grep -c 'opencode-subagent/scripts/delegate.sh' "$tmp_home/.claude/settings.json")"
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

# without the flag and without a TTY, nothing is written
rm -rf "$tmp_home/.claude/settings.json"
HOME="$tmp_home" "$repo_root/scripts/install.sh" --agent claude </dev/null >/dev/null
if [ -e "$tmp_home/.claude/settings.json" ]; then
  echo "FAIL  permissions written without consent" >&2
  exit 1
fi

# --doctor reports on the three CLIs and jq
out="$("$repo_root/scripts/install.sh" --doctor)"
for tool in claude codex opencode jq; do
  echo "$out" | grep -q "$tool" || { echo "FAIL  --doctor missing $tool" >&2; exit 1; }
done

echo "Installer tests passed."
