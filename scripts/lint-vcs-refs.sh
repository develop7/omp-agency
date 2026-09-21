#!/usr/bin/env bash
# Lint: check that skill markdown files don't contain raw VCS or forge commands
# where they should use the `vcs_read`/`vcs_write` and `forge` tools instead.
# Only checks executable-instruction patterns
# (commands an LLM agent would run during a workflow), not prose or examples.
#
# Usage:
#   lint-vcs-refs.sh [--strict]
#
#   --strict  Fail on any raw git/gh command (including prose). Default: fail
#             only on executable-instruction patterns.
#
# In addition to the raw-command scan this script checks tool-reference
# consistency in the reviewer skill files: every tool name those files instruct
# an executor to use must be on the executor's effective allowlist (see
# CHECK_REVIEWER_TOOL_REFS below).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="${SKILLS_DIR:-"$REPO_DIR/skills"}"

# Patterns that look like executable instructions to an LLM agent
# (backtick-wrapped commands, or standalone command instructions)
# VCS patterns → use vcs_read/vcs_write
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

# Forge patterns → use forge
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
# prose describing VCS tool internals (what the tool does under
# the hood), not as executable instructions. These are VCS-pattern exemptions only;
# forge patterns (`gh …`) scan every file — no file should contain raw forge
# commands after routing through the `forge` tool.
#
# VCS-exempt files:
# - do/SKILL.md, talk/SKILL.md (orchestration prose / talk-mode allows git)
# - nodes/branch.md, nodes/sync.md (describe VCS tool internals)
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
        echo "::error file=$skill_file::Raw VCS command pattern '$pattern' found. Use the vcs_read/vcs_write tools instead." >&2
        grep -n "$pattern" "$skill_file" 2>/dev/null
        violations=$((violations + 1))
      fi
    done
  fi
  if ! is_forge_exempt "$skill_file"; then
    for pattern in "${FORGE_PATTERNS[@]}"; do
      if grep -q "$pattern" "$skill_file" 2>/dev/null; then
        echo "::error file=$skill_file::Raw forge command pattern '$pattern' found. Use the forge tool instead." >&2
        grep -n "$pattern" "$skill_file" 2>/dev/null
        violations=$((violations + 1))
      fi
    done
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "Found $violations raw VCS/forge command pattern(s) in skill files." >&2
  echo "Replace with vcs_read/vcs_write or forge tool calls." >&2
  exit 1
fi

echo "No raw VCS or forge commands found in skill files."

# ---------------------------------------------------------------------------
# CHECK_REVIEWER_TOOL_REFS: tool-reference consistency check for reviewer
# skill files.
#
# Every tool reference a reviewer skill makes must be on the executor's
# effective allowlist:
#   - skills/{hickey,lowy,fact-check}/ run under the repo-owned reviewer
#     agents agents/{hickey,lowy}.md; their effective allowlist is the agent
#     frontmatter `tools:` list plus the tools registered by this repo's
#     extension src/agency-tools.ts (vcs_read, vcs_write, forge, workflow,
#     agency_driver). Extension-registered tools are force-included by the
#     harness even when a frontmatter allowlist omits them, so they count.
#   - skills/code-police/ spawns the bundled `scout` for passes 1-2. Its
#     effective allowlist is the bundled scout frontmatter allowlist plus the
#     extension-registered tools — the raw bundled frontmatter alone would
#     under-count, since extension tools are force-included in normal spawns.
# Only positive tool-instruction references are checked, anchored to call
# syntax: a backticked inline call shape (`tool {args: ...}`) or a backticked
# tool name directly followed by " tool" (`vcs_read` tool using ...). Prose
# identifiers (rule IDs, event names, code literals) and negated mentions
# ("Do not use the `ask` tool") are not executor instructions. References that
# belong to the orchestrator rather than the executor (e.g. code-police's
# `task` spawning and diff embedding) are likewise out of scope.
#
# Bundled-scout allowlist provenance: upstream oh-my-pi
# packages/coding-agent/src/prompts/agents/scout.md frontmatter
# (`tools: read, find, grep, glob, web_search`).
# ---------------------------------------------------------------------------

AGENTS_DIR="${AGENTS_DIR:-"$REPO_DIR/agents"}"

# Extension-registered tools (src/agency-tools.ts `pi.registerTool` names).
EXTENSION_TOOLS=(vcs_read vcs_write forge workflow agency_driver)

# Bundled scout allowlist (see provenance comment above).
SCOUT_TOOLS=(read find grep glob web_search)

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Emit the executor allowlist: frontmatter `tools:` (comma-separated) of the
# given agent file plus the extension-registered tools.
reviewer_tools() {
  local agent_file="$1"
  local line
  line="$(sed -n 's/^tools:[[:space:]]*//p' "$agent_file" | head -n 1)"
  if [ -n "$line" ]; then
    local IFS=','
    local tools=()
    read -r -a tools <<< "$line"
    local tool
    for tool in "${tools[@]}"; do
      printf '%s\n' "$(trim "$tool")"
    done
  fi
  local ext
  for ext in "${EXTENSION_TOOLS[@]}"; do
    printf '%s\n' "$ext"
  done
}

# Extract tool references anchored to call syntax. An inline span containing
# an `{ args: ...}` call shape yields its first word (e.g.
# `vcs_read {args: ["diff-range"]}`); a bare identifier span yields only when
# directly followed by " tool"/" tools" and not negated earlier on the line.
tool_refs_in_file() {
  awk '
  {
    s = $0
    while (match(s, /`[^`]+`/)) {
      span = substr(s, RSTART + 1, RLENGTH - 2)
      after = substr(s, RSTART + RLENGTH)
      before = substr(s, 1, RSTART - 1)
      tok = span
      if (index(span, "{") > 0 && span ~ /\{ ?args/) {
        sub(/[[:space:]].*/, "", tok)
        if (tok ~ /^[a-z_]+$/) print tok
      } else if (span ~ /^[a-z_]+$/ && after ~ /^ ?(tool|tools)([^a-zA-Z_]|$)/) {
        if (before !~ /[Nn]ot/ && before !~ /never/) print tok
      }
      s = substr(s, RSTART + RLENGTH)
    }
  }' "$1" | sort -u
}

check_tool_refs() {
  local file="$1" executor="$2"
  shift 2
  local found=0 tool candidate
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    candidate=""
    for candidate in "$@"; do
      [ "$candidate" = "$tool" ] && break
      candidate=""
    done
    if [ -z "$candidate" ]; then
      echo "::error file=$file::Tool reference '$tool' is not on the $executor effective allowlist." >&2
      found=$((found + 1))
    fi
  done < <(tool_refs_in_file "$file")
  tool_violations=$((tool_violations + found))
}

tool_violations=0

# Reviewer-agent skills: checked only when the agent definitions are present
# (fixture test runs without an agents/ tree skip this check).
if [ -f "$AGENTS_DIR/hickey.md" ] && [ -f "$AGENTS_DIR/lowy.md" ]; then
  REVIEWER_ALLOWLIST=()
  mapfile -t REVIEWER_ALLOWLIST < <(reviewer_tools "$AGENTS_DIR/hickey.md")
  # lowy.md must declare the same allowlist; verify rather than merge.
  if ! diff <(reviewer_tools "$AGENTS_DIR/hickey.md") <(reviewer_tools "$AGENTS_DIR/lowy.md") >/dev/null; then
    echo "::error file=$AGENTS_DIR/lowy.md::Reviewer agent frontmatter tools differ from agents/hickey.md." >&2
    tool_violations=$((tool_violations + 1))
  fi
  for reviewer_file in "$SKILLS_DIR"/hickey/*.md "$SKILLS_DIR"/lowy/*.md "$SKILLS_DIR"/fact-check/*.md; do
    [ -f "$reviewer_file" ] || continue
    check_tool_refs "$reviewer_file" "reviewer-agent" "${REVIEWER_ALLOWLIST[@]}"
  done
fi

# Code-police: passes 1-2 run as bundled-scout sub-agents; effective allowlist
# is the scout frontmatter list plus the extension-registered tools.
for police_file in "$SKILLS_DIR"/code-police/*.md; do
  [ -f "$police_file" ] || continue
  check_tool_refs "$police_file" "scout" "${SCOUT_TOOLS[@]}" "${EXTENSION_TOOLS[@]}"
done

if [ "$tool_violations" -gt 0 ]; then
  echo "Found $tool_violations tool-reference violation(s) in reviewer skill files." >&2
  echo "Remove the reference or add the tool to the executor's allowlist (agents/*.md frontmatter or src/agency-tools.ts)." >&2
  exit 1
fi

echo "Reviewer skill tool references are consistent with the effective allowlists."
