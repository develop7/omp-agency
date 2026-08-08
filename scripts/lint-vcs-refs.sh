#!/usr/bin/env bash
# Lint: check that skill markdown files don't contain raw VCS or forge commands
# where they should use the VCS/forge-agnostic dispatchers (`scripts/vcs-op`,
# `scripts/forge-op`) instead. Only checks executable-instruction patterns
# (commands an LLM agent would run during a workflow), not prose or examples.
#
# Usage:
#   lint-vcs-refs.sh [--strict]
#
#   --strict  Fail on any raw git/gh command (including prose). Default: fail
#             only on executable-instruction patterns.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="${SKILLS_DIR:-"$REPO_DIR/skills"}"

# Patterns that look like executable instructions to an LLM agent
# (backtick-wrapped commands, or standalone command instructions)
# VCS patterns → use scripts/vcs-op
VCS_PATTERNS=(
  'git diff '
  'git push '
  'git log '
  'git commit '
  'git add '
  'git branch '
  'git rev-parse '
  'git symbolic-ref '
  'git status --porcelain'
  'git remote get-url'
  'git pull --ff-only'
  'git remote set-head'
  'jj diff '
  'jj log '
  'jj bookmark '
  'jj git fetch'
  'jj git push'
  'jj git remote'
  'jj describe'
  'jj new '
  'jj file list'
)

# Forge patterns → use scripts/forge-op
FORGE_PATTERNS=(
  'gh pr create'
  'gh pr view'
  'gh pr edit'
  'gh pr comment'
  'gh pr checks'
  'gh issue view'
)

strict=false
for arg in "$@"; do
  case "$arg" in
    --strict) strict=true ;;
    *) echo "lint-vcs-refs: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

violations=0

# Non-strict skips: allow git/jj references in files where they appear as
# prose describing vcs-op's internal behavior (what the script does under the
# hood), not as executable instructions. These are VCS-pattern exemptions only;
# forge patterns (`gh …`) scan every file — no file should contain raw forge
# commands after routing through forge-op.
#
# VCS-exempt files:
# - do/SKILL.md, talk/SKILL.md (orchestration prose / talk-mode allows git)
# - nodes/branch.md, nodes/sync.md (describe vcs-op internals)
is_vcs_exempt() {
  [ "$strict" = false ] || return 1
  case "$1" in
    */do/SKILL.md)            return 0 ;;
    */talk/SKILL.md)          return 0 ;;
    */do/nodes/branch.md)    return 0 ;;
    */do/nodes/sync.md)      return 0 ;;
    *)                        return 1 ;;
  esac
}

# No file is exempt from forge-pattern scanning.
is_forge_exempt() {
  return 1
}

# Scan all markdown under skills/ — not just SKILL.md. Most forge/VCS calls
# live in nodes/*.md (the do workflow's step activities), which the previous
# SKILL.md-only scope missed entirely.
shopt -s globstar
for skill_file in "$SKILLS_DIR"/**/*.md; do
  [ -f "$skill_file" ] || continue
  if ! is_vcs_exempt "$skill_file"; then
    for pattern in "${VCS_PATTERNS[@]}"; do
      if grep -q "$pattern" "$skill_file" 2>/dev/null; then
        echo "::error file=$skill_file::Raw VCS command pattern '$pattern' found. Use \`.../skills/do/scripts/vcs-op\` instead." >&2
        grep -n "$pattern" "$skill_file" 2>/dev/null
        violations=$((violations + 1))
      fi
    done
  fi
  if ! is_forge_exempt "$skill_file"; then
    for pattern in "${FORGE_PATTERNS[@]}"; do
      if grep -q "$pattern" "$skill_file" 2>/dev/null; then
        echo "::error file=$skill_file::Raw forge command pattern '$pattern' found. Use \`.../skills/do/scripts/forge-op\` instead." >&2
        grep -n "$pattern" "$skill_file" 2>/dev/null
        violations=$((violations + 1))
      fi
    done
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "Found $violations raw VCS/forge command pattern(s) in skill files." >&2
  echo "Replace with \`.../skills/do/scripts/vcs-op <semantic-op>\` or \`.../skills/do/scripts/forge-op <op>\` calls." >&2
  exit 1
fi

echo "No raw VCS or forge commands found in skill files."
