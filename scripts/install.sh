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
#   scripts/install.sh --subagent-permissions  # also pre-authorize subagent delegation (consent)
#   scripts/install.sh --doctor    # check for claude/codex/opencode/jq on PATH
#
# Symlinks are the default so edits in this repo take effect immediately.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_src="$repo_root/skills"

mode="symlink"
subagent_permissions="ask"
targets=()
selected_targets=0
selected_hosts=()

agent_names=(claude agents codex gemini antigravity opencode)

usage() {
  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

add_host() {
  local host="$1"
  local existing

  for existing in "${selected_hosts[@]}"; do
    if [ "$existing" = "$host" ]; then
      return
    fi
  done

  selected_hosts+=("$host")
}

add_agent() {
  case "$1" in
    claude)
      add_target "$HOME/.claude/skills"
      add_host "claude"
      ;;
    agents)
      add_target "$HOME/.agents/skills"
      ;;
    codex)
      add_target "$HOME/.agents/skills"
      add_target "$HOME/.codex/skills"
      add_host "codex"
      ;;
    gemini)
      add_target "$HOME/.gemini/skills"
      ;;
    antigravity)
      add_target "$HOME/.gemini/antigravity/skills"
      ;;
    opencode)
      add_target "$HOME/.config/opencode/skills"
      add_host "opencode"
      ;;
    *)
      echo "unknown agent: $1" >&2
      echo "known agents:" >&2
      list_agents >&2
      exit 1
      ;;
  esac
}

doctor() {
  local tool
  for tool in claude codex opencode jq; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%-10s ok    %s\n' "$tool" "$("$tool" --version 2>/dev/null | head -1)"
    else
      printf '%-10s MISSING\n' "$tool"
    fi
  done
}

setup_claude_permissions() {
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 required to edit ~/.claude/settings.json" >&2; return 0; }
  python3 - "$HOME/.claude/settings.json" "$HOME" <<'PY'
import json, os, sys
path, home = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
allow = data.setdefault("permissions", {}).setdefault("allow", [])
for skill in ("claude-subagent", "codex-subagent", "opencode-subagent"):
    rule = f"Bash(bash {home}/.claude/skills/{skill}/scripts/delegate.sh:*)"
    if rule not in allow:
        allow.append(rule)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  echo "claude: delegation allow rules written to ~/.claude/settings.json"
}

setup_codex_permissions() {
  local config="$HOME/.codex/config.toml"
  mkdir -p "$(dirname "$config")"
  touch "$config"
  if grep -q '^\[sandbox_workspace_write\]' "$config"; then
    if ! grep -q 'network_access *= *true' "$config"; then
      echo "codex: ~/.codex/config.toml already defines [sandbox_workspace_write]; add 'network_access = true' to it manually (nested subagent CLIs need network)." >&2
    fi
  else
    printf '\n# workflow-skills subagents: nested CLIs need network access\n[sandbox_workspace_write]\nnetwork_access = true\n' >>"$config"
    echo "codex: network access enabled for workspace-write sandbox in ~/.codex/config.toml"
  fi
}

setup_opencode_permissions() {
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 required to edit opencode.json" >&2; return 0; }
  python3 - "$HOME/.config/opencode/opencode.json" <<'PY'
import json, os, sys
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
data.setdefault("permission", {}).setdefault("bash", {})["*delegate.sh*"] = "allow"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  echo "opencode: delegate.sh bash permission written to ~/.config/opencode/opencode.json"
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
    --subagent-permissions)
      subagent_permissions="yes"
      ;;
    --doctor)
      doctor
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

maybe_setup_permissions() {
  local host="$1"
  local answer
  case "$subagent_permissions" in
    yes) "setup_${host}_permissions" ;;
    ask)
      if [ -t 0 ]; then
        read -r -p "Pre-authorize subagent delegation for $host (writes to its config)? [y/N] " answer
        case "$answer" in
          y|Y|yes) "setup_${host}_permissions" ;;
          *) echo "$host: skipped; re-run with --subagent-permissions to enable later" ;;
        esac
      fi
      ;;
  esac
}

if [ "${#selected_hosts[@]}" -gt 0 ]; then
  for host in "${selected_hosts[@]}"; do
    maybe_setup_permissions "$host"
  done
fi

printf 'Done. Installed into:\n'
printf '  %s\n' "${targets[@]}"
