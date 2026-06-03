#!/usr/bin/env bash
# Install the skills in this repo into your agent's skills directory.
#
# Usage:
#   scripts/install.sh             # symlink into ~/.claude/skills (default)
#   scripts/install.sh --agent NAME # symlink into a known agent skills directory
#   scripts/install.sh --all        # symlink into every known agent skills directory
#   scripts/install.sh --agents     # alias for --agent agents
#   scripts/install.sh --copy      # copy instead of symlink
#   scripts/install.sh --dir PATH  # install into a custom skills directory
#   scripts/install.sh --list-agents
#
# Symlinks are the default so edits in this repo take effect immediately.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_src="$repo_root/skills"

mode="symlink"
targets=()
selected_targets=0

agent_names=(claude agents codex gemini antigravity opencode)

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

list_agents() {
  printf '%s\n' "${agent_names[@]}"
}

add_target() {
  local target="$1"
  local existing

  for existing in "${targets[@]}"; do
    if [ "$existing" = "$target" ]; then
      return
    fi
  done

  targets+=("$target")
}

add_agent() {
  case "$1" in
    claude)
      add_target "$HOME/.claude/skills"
      ;;
    agents)
      add_target "$HOME/.agents/skills"
      ;;
    codex)
      add_target "$HOME/.agents/skills"
      add_target "$HOME/.codex/skills"
      ;;
    gemini)
      add_target "$HOME/.gemini/skills"
      ;;
    antigravity)
      add_target "$HOME/.gemini/antigravity/skills"
      ;;
    opencode)
      add_target "$HOME/.config/opencode/skills"
      ;;
    *)
      echo "unknown agent: $1" >&2
      echo "known agents:" >&2
      list_agents >&2
      exit 1
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      shift
      add_agent "${1:?--agent requires a name}"
      selected_targets=1
      ;;
    --agents)
      add_agent agents
      selected_targets=1
      ;;
    --all)
      for agent in "${agent_names[@]}"; do
        add_agent "$agent"
      done
      selected_targets=1
      ;;
    --copy)
      mode="copy"
      ;;
    --dir)
      shift
      add_target "${1:?--dir requires a path}"
      selected_targets=1
      ;;
    --list-agents)
      list_agents
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$selected_targets" -eq 0 ]; then
  add_agent claude
fi

install_into() {
  local target="$1"
  local dir
  local name
  local dest

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
}

for target in "${targets[@]}"; do
  install_into "$target"
done

printf 'Done. Installed into:\n'
printf '  %s\n' "${targets[@]}"
