# Shared state-reading helpers for do/ skill scripts.
#
# Sourced by vcs-op, forge-op, and any other script that needs to read
# top-level fields from .do-results.json. Centralizes jq resolution
# (with a nix fallback) and the state_get reader so every consumer uses
# the same mechanism — previously vcs-op inlined this; duplicating it in
# forge-op would have been the second copy.
#
# The file is cwd-relative (repo root): matches how do-results resolves
# FILE=".do-results.json". The workflow always invokes scripts from the
# repo root.
#
# Usage (source, don't execute):
#   source "$SCRIPT_DIR/lib/state.sh"
#   state_get vcs     # → prints value or empty string if absent

# Resolve jq once, falling back to nix if not on PATH.
if ! command -v jq &>/dev/null; then
  command -v nix &>/dev/null && JQ="nix run nixpkgs#jq --" || JQ=jq
else
  JQ=jq
fi

STATE_FILE=".do-results.json"

# Read a top-level field from .do-results.json. Prints empty (not error) if
# the file or field is absent or jq is unavailable — callers decide whether
# an empty result is fatal. Mirrors vcs-op's original state_get semantics.
state_get() {
  [ -f "$STATE_FILE" ] || return 0
  "$JQ" -r ".${1:?field required} // \"\"" "$STATE_FILE" 2>/dev/null || true
}