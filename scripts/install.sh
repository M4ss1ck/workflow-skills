#!/usr/bin/env bash
# Install the skills in this repo into your agent's skills directory.
#
# Usage:
#   scripts/install.sh             # symlink into ~/.claude/skills (default)
#   scripts/install.sh --agents    # symlink into ~/.agents/skills (Codex/agent-agnostic)
#   scripts/install.sh --copy      # copy instead of symlink
#   scripts/install.sh --dir PATH  # install into a custom skills directory
#
# Symlinks are the default so edits in this repo take effect immediately.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_src="$repo_root/skills"

target="$HOME/.claude/skills"
mode="symlink"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agents) target="$HOME/.agents/skills" ;;
    --copy)   mode="copy" ;;
    --dir)    shift; target="${1:?--dir requires a path}" ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$target"

for dir in "$skills_src"/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  dest="$target/$name"

  rm -rf "$dest"
  if [ "$mode" = "copy" ]; then
    cp -R "$dir" "$dest"
    echo "copied   $name -> $dest"
  else
    ln -s "${dir%/}" "$dest"
    echo "linked   $name -> $dest"
  fi
done

echo "Done. Installed into $target"
