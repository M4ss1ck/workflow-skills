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
#   scripts/install.sh --no-hooks  # skip native delegation routing hooks (claude/codex)
#   scripts/install.sh --remove-hooks --agent NAME  # remove only the routing hooks this installer added
#
# Symlinks are the default so edits in this repo take effect immediately.
# Selecting claude or codex also registers the delegation routing hooks.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_src="$repo_root/skills"

mode="symlink"
subagent_permissions="ask"
targets=()
selected_targets=0
selected_hosts=()
hooks_mode="install"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
runtime_dir="$data_home/workflow-skills/opencode-subagent"
runtime_marker=".installed-by-workflow-skills"

agent_names=(claude agents codex gemini antigravity opencode)

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
  if command -v opencode-delegate >/dev/null 2>&1; then
    printf '%-10s ok    %s\n' "delegate" "$(command -v opencode-delegate)"
  else
    printf '%-10s none  opencode-delegate not on PATH (run install.sh to add it)\n' "delegate"
  fi
  local worker="$HOME/.config/opencode/agent/workflow-worker.md"
  if [ -e "$worker" ]; then
    printf '%-10s ok    %s\n' "worker" "$worker"
  else
    printf '%-10s none  %s (delegate.sh installs it on first launch)\n' "worker" "$worker"
  fi
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/workflow-skills/subagents.conf"
  if [ -f "$conf" ]; then
    printf '%-10s ok    %s\n' "conf" "$conf"
    sed 's/^/           /' "$conf"
  else
    printf '%-10s none  %s (no saved subagent model defaults)\n' "conf" "$conf"
  fi
  if command -v opencode-delegate >/dev/null 2>&1 && opencode-delegate route identity >/dev/null 2>&1; then
    printf '%-10s\n' "routing"
    opencode-delegate route doctor 2>&1 | sed 's/^/           /' || true
  else
    printf '%-10s none  opencode-delegate on PATH has no routing (re-run install.sh)\n' "routing"
  fi
}

# Agents reach delegate.sh from whatever cwd they happen to be in, and guessing
# a relative path is the single most common way they fail to reach it at all.
# One name on PATH, pointing at this checkout, works from every host.
# The executable authority for PATH and local hooks. Symlink mode runs the
# checkout; copy mode runs one owned copy under XDG_DATA_HOME, so both survive
# the checkout being moved or deleted.
delegate_entry() {
  if [ "$mode" = "copy" ]; then
    echo "$runtime_dir/scripts/delegate.sh"
  else
    echo "$repo_root/skills/opencode-subagent/scripts/delegate.sh"
  fi
}

install_runtime() {
  local src="$skills_src/opencode-subagent"
  local tmp

  [ "$mode" = "copy" ] || return 0
  [ -d "$src" ] || return 0
  if [ -e "$runtime_dir" ] && [ ! -e "$runtime_dir/$runtime_marker" ]; then
    echo "runtime  $runtime_dir exists and was not installed by workflow-skills; leaving it alone" >&2
    runtime_conflict=1
    return 0
  fi
  mkdir -p "$(dirname "$runtime_dir")"
  tmp="$runtime_dir.tmp.$$"
  rm -rf "$tmp"
  cp -R "$src" "$tmp"
  rm -rf "$tmp/scripts/__pycache__"
  : >"$tmp/$runtime_marker"
  # Swap by rename: hooks firing mid-install see the old or the new runtime,
  # never a missing one.
  if [ -e "$runtime_dir" ]; then
    rm -rf "$runtime_dir.old.$$"
    mv "$runtime_dir" "$runtime_dir.old.$$"
  fi
  mv "$tmp" "$runtime_dir"
  rm -rf "$runtime_dir.old.$$"
  echo "runtime  opencode-subagent -> $runtime_dir"
}
runtime_conflict=0

install_delegate_command() {
  local src
  src="$(delegate_entry)"
  local bin_dir="$HOME/.local/bin"
  local dest="$bin_dir/opencode-delegate"
  local current=""

  [ -f "$src" ] || return 0
  [ "$runtime_conflict" -eq 0 ] || return 0

  if [ -L "$dest" ]; then
    current="$(readlink "$dest")"
  elif [ -e "$dest" ]; then
    echo "command  opencode-delegate -> $dest exists and is not a symlink; leaving it alone" >&2
    return 0
  fi

  mkdir -p "$bin_dir"
  if [ -n "$current" ] && [ "$current" != "$src" ]; then
    echo "command  opencode-delegate REPOINTED from $current"
  fi
  ln -sfn "$src" "$dest"
  echo "command  opencode-delegate -> $dest"

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "command  NOTE: $bin_dir is not on your PATH; add it or call the script by path" >&2 ;;
  esac
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
rules = [
    f"Bash(bash {home}/.claude/skills/opencode-subagent/scripts/delegate.sh:*)",
    "Bash(opencode-delegate:*)",
]
for rule in rules:
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
bash_rules = data.setdefault("permission", {}).setdefault("bash", {})
bash_rules["*delegate.sh*"] = "allow"
bash_rules["*opencode-delegate*"] = "allow"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  echo "opencode: delegate.sh bash permission written to ~/.config/opencode/opencode.json"
}

# Native delegation routing hooks. Each owned handler carries the marker
# comment, so reruns replace exactly our entries and removal never touches
# anyone else's hooks. Commands use absolute interpreter and entry paths: a
# host's hook environment need not have ~/.local/bin or python3 on PATH.
hooks_marker="workflow-skills-routing"
hook_shim="$data_home/workflow-skills/route-hook-shim.sh"

install_hook_shim() {
  mkdir -p "$(dirname "$hook_shim")"
  cp "$skills_src/opencode-subagent/scripts/route-hook-shim.sh" "$hook_shim.tmp.$$"
  chmod 755 "$hook_shim.tmp.$$"
  mv "$hook_shim.tmp.$$" "$hook_shim"
}

plugin_registered() {
  case "$1" in
    claude)
      [ -f "$HOME/.claude/plugins/installed_plugins.json" ] \
        && grep -q '"workflow-skills@' "$HOME/.claude/plugins/installed_plugins.json" ;;
    codex)
      [ -f "$HOME/.codex/config.toml" ] \
        && grep -q '^\[plugins\."workflow-skills@' "$HOME/.codex/config.toml" ;;
  esac
}

hooks_file_for() {
  case "$1" in
    claude) echo "$HOME/.claude/settings.json" ;;
    codex)  echo "$HOME/.codex/hooks.json" ;;
  esac
}

merge_hooks() {
  local host="$1" action="$2" python="$3" entry="${4:-}"
  local bash_path
  bash_path="$(command -v bash)"
  "$python" - "$(hooks_file_for "$host")" "$action" "$host" "$hooks_marker" "$python" "$bash_path" "$entry" "$repo_root/hooks/hooks.json" "$hook_shim" <<'PY'
import json, os, shlex, stat, sys
path, action, host, marker, python, bash, entry, template, shim = sys.argv[1:]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
hooks = data.get("hooks", {})
removed = 0
for event in list(hooks):
    groups = []
    for group in hooks[event]:
        kept = [h for h in group.get("hooks", []) if marker not in h.get("command", "")]
        removed += len(group.get("hooks", [])) - len(kept)
        if kept:
            groups.append(dict(group, hooks=kept))
    if groups:
        hooks[event] = groups
    else:
        del hooks[event]
if action == "install":
    with open(template) as f:
        shipped = json.load(f)["hooks"]
    command = (f"OPENCODE_DELEGATE_PYTHON={shlex.quote(python)} {shlex.quote(bash)} {shlex.quote(shim)} "
               f"{shlex.quote(entry)} {host} # {marker}")
    for event, groups in shipped.items():
        for group in groups:
            handlers = [dict(h, command=command) for h in group["hooks"]]
            hooks.setdefault(event, []).append(dict(group, hooks=handlers))
if hooks:
    data["hooks"] = hooks
else:
    data.pop("hooks", None)
if action == "remove" and not removed:
    print("none")
    sys.exit(0)
# Write through a symlinked settings file (dotfiles) and keep its mode.
target = os.path.realpath(path)
os.makedirs(os.path.dirname(target), exist_ok=True)
mode = stat.S_IMODE(os.stat(target).st_mode) if os.path.exists(target) else 0o600
tmp = f"{target}.workflow-skills.{os.getpid()}.tmp"
with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, target)
print(removed)
PY
}

install_hooks() {
  local host="$1" python entry result
  if [ "$hooks_mode" = "skip" ]; then
    echo "hooks    $host: skipped (--no-hooks); native delegation is not routed"
    return 0
  fi
  if plugin_registered "$host"; then
    echo "hooks    $host: the workflow-skills plugin is installed and ships these hooks; not adding a duplicate local registration"
    if [ "$host" = "codex" ]; then
      echo "hooks    codex: WARNING: plugin-bundled routing hooks are not verified on Codex; enforcement is unverified until opencode-delegate route doctor shows active-observed" >&2
    fi
    return 0
  fi
  python="$(command -v python3 || true)"
  if [ -z "$python" ]; then
    echo "hooks    $host: NOT installed: python3 is required for delegation routing" >&2
    return 0
  fi
  if [ "$runtime_conflict" -ne 0 ]; then
    echo "hooks    $host: NOT installed: resolve the runtime conflict above first" >&2
    return 0
  fi
  entry="$(delegate_entry)"
  install_hook_shim
  result="$(merge_hooks "$host" install "$python" "$entry")"
  echo "hooks    $host: routing hooks -> $(hooks_file_for "$host") (replaced $result earlier entries)"
  case "$host" in
    claude) echo "hooks    claude: start a new Claude Code session to load them; check with: opencode-delegate route doctor" ;;
    codex)  echo "hooks    codex: Codex skips new hooks until you trust them: run /hooks in Codex and trust the workflow-skills routing entries" ;;
  esac
}

remove_hooks() {
  local host="$1" python result
  python="$(command -v python3 || true)"
  [ -n "$python" ] || { echo "hooks    $host: python3 is required to edit $(hooks_file_for "$host")" >&2; return 1; }
  [ -f "$(hooks_file_for "$host")" ] || { echo "hooks    $host: nothing to remove"; return 0; }
  result="$(merge_hooks "$host" remove "$python")"
  if [ "$result" = "none" ]; then
    echo "hooks    $host: nothing to remove"
  else
    echo "hooks    $host: removed $result routing hook entries from $(hooks_file_for "$host"); start a new session"
  fi
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
    --no-hooks)
      hooks_mode="skip"
      ;;
    --remove-hooks)
      hooks_mode="remove"
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ "$selected_targets" -eq 0 ]; then
  add_agent claude
fi

if [ "$hooks_mode" = "remove" ]; then
  status=0
  for host in ${selected_hosts[@]+"${selected_hosts[@]}"}; do
    case "$host" in claude|codex) remove_hooks "$host" || status=1 ;; esac
  done
  exit "$status"
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

# Skills that ship an OpenCode agent definition need it in OpenCode's agent
# directory, otherwise `opencode run --agent NAME` silently falls back to the
# unconstrained default agent.
install_opencode_agents() {
  local dest_dir="$HOME/.config/opencode/agent"
  local src name

  mkdir -p "$dest_dir"
  for src in "$skills_src"/*/agents/*.md; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    rm -f "$dest_dir/$name"
    if [ "$mode" = "copy" ]; then
      cp "$src" "$dest_dir/$name"
    else
      ln -s "$src" "$dest_dir/$name"
    fi
    echo "agent    ${name%.md} -> $dest_dir/$name"
  done
}

for target in "${targets[@]}"; do
  install_into "$target"
done

install_runtime
install_delegate_command

enforcing=0
for host in ${selected_hosts[@]+"${selected_hosts[@]}"}; do
  case "$host" in
    opencode) install_opencode_agents ;;
    claude|codex) install_hooks "$host"; enforcing=1 ;;
  esac
done
if [ "$enforcing" -eq 0 ]; then
  echo "hooks    native delegation routing is enforced only for --agent claude or --agent codex; not available for these targets"
fi

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
