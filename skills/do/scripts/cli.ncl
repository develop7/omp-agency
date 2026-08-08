# Workflow CLI entry point — reference only.
#
# The active entry point is scripts/nickel-cli, which constructs the Nickel
# expression inline with absolute paths (workflow.ncl via $SCRIPT_DIR,
# .do-results.json via $PWD). This file is kept for documentation of the
# intended interface; nickel-cli no longer imports it.
#
# nickel-cli equivalent:
#   let workflow = import "$SCRIPT_DIR/../workflow.ncl" in
#   let state = workflow.normalize_state (import "$PWD/.do-results.json") in
#   workflow.cli state
{
  cli
    | doc "Returns the next step to execute given current state."
    =
      let workflow = import "../workflow.ncl" in
      let state = workflow.normalize_state (import "../../../.do-results.json") in
      workflow.cli state,

  cli_seed
    | doc "Returns the seeded step list for the given entry point."
    = fun from =>
      let workflow = import "../workflow.ncl" in
      let state = workflow.normalize_state (import "../../../.do-results.json") in
      workflow.cli_seed from state,
}
