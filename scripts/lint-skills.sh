#!/usr/bin/env bash
# Validate that every skill has a well-formed SKILL.md with required frontmatter.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_dir="$repo_root/skills"
status=0

if [ ! -d "$skills_dir" ]; then
  echo "error: no skills/ directory found at $skills_dir" >&2
  exit 1
fi

found=0
for dir in "$skills_dir"/*/; do
  [ -d "$dir" ] || continue
  found=1
  name="$(basename "$dir")"
  file="$dir/SKILL.md"
  skill_status=0

  if [ ! -f "$file" ]; then
    echo "FAIL  $name: missing SKILL.md"
    status=1
    continue
  fi

  # Frontmatter must be the first thing in the file.
  if [ "$(head -n 1 "$file")" != "---" ]; then
    echo "FAIL  $name: SKILL.md must start with '---' frontmatter"
    status=1
    continue
  fi

  # Extract the frontmatter block (between the first two '---' lines).
  frontmatter="$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$file")"
  declared_name="$(printf '%s\n' "$frontmatter" | awk -F: '/^name:[[:space:]]*/ {sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); gsub(/^'\''|'\''$/, "", $2); gsub(/^"|"$/, "", $2); print $2; exit}')"

  for key in name description; do
    if ! printf '%s\n' "$frontmatter" | grep -Eq "^${key}:[[:space:]]*\S"; then
      echo "FAIL  $name: frontmatter missing non-empty '${key}'"
      status=1
      skill_status=1
    fi
  done

  if ! printf '%s\n' "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    echo "FAIL  $name: name must be kebab-case"
    status=1
    skill_status=1
  fi

  if [ -n "$declared_name" ] && [ "$declared_name" != "$name" ]; then
    echo "FAIL  $name: frontmatter name must match directory"
    status=1
    skill_status=1
  fi

  if [ "$skill_status" -eq 0 ]; then
    echo "ok    $name"
  fi
done

if [ "$found" -eq 0 ]; then
  echo "error: no skill directories found under $skills_dir" >&2
  exit 1
fi

if [ "$status" -eq 0 ]; then
  echo "All skills passed."
fi
exit "$status"
