// Shared workflow-state fixture for the runtime-level test suites. Both the
// adapter tests (tests/plugin/plugin-surface.mjs) and the Nickel smoke suite
// (nickel-vm/scripts/smoke.mjs) drive the same workflow contract against the
// same canonical running state, so the literal lives here.
export const TEST_STATE = {
  active: "working",
  status: "running",
  steps: [],
  noVcs: false,
  minimal: false,
  review: false,
  forge: "github",
  supportsPrCreate: true,
  supportsPrComment: true,
  supportsIssueView: true,
  supportsPrChecks: true,
  task: "test",
};
