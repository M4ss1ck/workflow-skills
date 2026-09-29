#!/usr/bin/env bash
# Validate lint failures for malformed skill metadata.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skills_dir="$repo_root/skills"
bad_dir="$skills_dir/lint-test-mismatch"
bad_case_dir="$skills_dir/Lint-Test-Bad-Case"
bad_external_dir="$repo_root/templates/lint-test-installable"
nested_worktree="$(mktemp -d "$repo_root/templates/lint-test-nested.XXXXXX")"

cleanup() {
  rm -rf "$bad_dir" "$bad_case_dir" "$bad_external_dir" "$nested_worktree"
}
trap cleanup EXIT

cleanup

mkdir -p "$bad_dir" "$bad_case_dir"
printf '%s\n' \
  '---' \
  'name: different-name' \
  'description: Use when testing linter mismatch handling.' \
  '---' \
  >"$bad_dir/SKILL.md"

printf '%s\n' \
  '---' \
  'name: Lint-Test-Bad-Case' \
  'description: Use when testing linter name format handling.' \
  '---' \
  >"$bad_case_dir/SKILL.md"

mkdir -p "$bad_external_dir"
printf '%s\n' \
  '---' \
  'name: lint-test-installable' \
  'description: Use when testing accidental installable manifests outside skills.' \
  '---' \
  >"$bad_external_dir/SKILL.md"

mkdir -p "$nested_worktree/skills/foreign-skill"
printf 'gitdir: /tmp/lint-test-nested.git\n' >"$nested_worktree/.git"
printf '%s\n' '---' 'name: foreign-skill' 'description: nested checkout' '---' \
  >"$nested_worktree/skills/foreign-skill/SKILL.md"

if bash "$repo_root/scripts/lint-skills.sh" >/tmp/workflow-skills-lint-test.out 2>&1; then
  cat /tmp/workflow-skills-lint-test.out >&2
  echo "FAIL  expected linter to reject mismatched and non-kebab-case names" >&2
  exit 1
fi

if ! grep -q "frontmatter name must match directory" /tmp/workflow-skills-lint-test.out; then
  cat /tmp/workflow-skills-lint-test.out >&2
  echo "FAIL  expected mismatch error" >&2
  exit 1
fi

if ! grep -q "name must be kebab-case" /tmp/workflow-skills-lint-test.out; then
  cat /tmp/workflow-skills-lint-test.out >&2
  echo "FAIL  expected kebab-case error" >&2
  exit 1
fi

if ! grep -q "SKILL.md outside skills/ is installable" /tmp/workflow-skills-lint-test.out; then
  cat /tmp/workflow-skills-lint-test.out >&2
  echo "FAIL  expected external SKILL.md error" >&2
  exit 1
fi

if grep -q 'lint-test-nested' /tmp/workflow-skills-lint-test.out; then
  cat /tmp/workflow-skills-lint-test.out >&2
  echo "FAIL  nested Git worktree was scanned as this checkout" >&2
  exit 1
fi

echo "Lint tests passed."
