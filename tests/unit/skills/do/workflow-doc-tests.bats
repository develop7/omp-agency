#!/usr/bin/env bats
#
# workflow.ncl's | doc examples are executable documentation: `nickel test`
# evaluates every `# =>` example, so stale documented behavior fails here
# instead of rotting silently. Production resolves the vocabulary import
# through the WASM in-memory seam; these tests satisfy it with a scratch copy
# so the stock CLI remains the sole owner of doc-test semantics.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir
  cp "$REPO_ROOT/skills/do/workflow.ncl" .
  cp "$REPO_ROOT/skills/do/workflow-manifest.json" .
  # Rewrite the in-memory seam to a local import. If the seam spelling ever
  # changes, the rewrite misses and the %inmem_src% assertion below fails
  # loudly instead of surfacing as a confusing resolution error.
  sed -i 's|import "%inmem_src%:workflow-manifest.json"|import "workflow-manifest.json"|' workflow.ncl
}

teardown() {
  teardown_test_dir
}

@test "vocabulary import seam is rewritten for the stock CLI" {
  run grep -c '%inmem_src%' workflow.ncl
  [ "$output" = "0" ]
}

@test "nickel test executes plain-fence doc examples (mutation guard)" {
  # If fence collection ever drifts, `nickel test` could pass having run zero
  # examples. Corrupting one known expectation must make it fail, proving the
  # plain-fence example executes.
  sed -i "s|# => 'github|# => 'gitea|" workflow.ncl
  run nickel test workflow.ncl
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "nickel test executes multiline-fence doc examples (mutation guard)" {
  # The plain-fence guard cannot see multiline fences silently dropping out of
  # collection (bad label, splitting change); corrupting one of their
  # expectations must fail too.
  sed -i 's|# => "plan-approval"|# => "bogus"|' workflow.ncl
  run nickel test workflow.ncl
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "workflow.ncl documentation examples pass nickel test" {
  run nickel test workflow.ncl
  echo "$output"
  [ "$status" -eq 0 ]
}
