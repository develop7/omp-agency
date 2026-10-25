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
  # Strip the in-memory seam prefix so the vocabulary import resolves against
  # the scratch copy; the %inmem_src% assertion below fails loudly if the
  # strip ever misses.
  sed -i 's|%inmem_src%:||' workflow.ncl
}

teardown() {
  teardown_test_dir
}

# Run the doctest suite and surface its output; callers assert on
# $status/$output (the repo's run_* helper idiom).
run_nickel_test() {
  run nickel test workflow.ncl
  echo "$output"
}

@test "vocabulary import seam is rewritten for the stock CLI" {
  # Presence in the source (there is a seam to strip) and absence in the
  # scratch copy (the strip worked): neither check alone distinguishes a
  # rewrite from a prefix-less source passing vacuously.
  run grep -c '%inmem_src%:' "$REPO_ROOT/skills/do/workflow.ncl"
  [ "$output" -ge 1 ]
  run grep -c '%inmem_src%' workflow.ncl
  [ "$output" = "0" ]
}

@test "nickel test executes plain-fence doc examples (mutation guard)" {
  # If fence collection ever drifts, `nickel test` could pass having run zero
  # examples. Corrupting one known expectation must make it fail, proving the
  # plain-fence example executes.
  sed -i "s|# => 'github|# => 'gitea|" workflow.ncl
  run_nickel_test
  [[ $output == *gitea* ]]
  [ "$status" -ne 0 ]
}

@test "nickel test executes multiline-fence doc examples (mutation guard)" {
  # The plain-fence guard cannot see multiline fences silently dropping out of
  # collection (bad label, splitting change); corrupting one of their
  # expectations must fail too.
  sed -i 's|# => "plan-approval"|# => "bogus"|' workflow.ncl
  run_nickel_test
  [[ $output == *bogus* ]]
  [ "$status" -ne 0 ]
}

@test "workflow.ncl documentation examples pass nickel test" {
  run_nickel_test
  [ "$status" -eq 0 ]
}
