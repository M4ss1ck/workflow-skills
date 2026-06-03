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

echo "Installer tests passed."
