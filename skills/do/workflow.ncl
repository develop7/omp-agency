# workflow.ncl — /do workflow engine
#
# Three boundaries:
#   Vocabulary: workflow-manifest.json (step order and entry-point targets)
#   State:      .do-results.json managed by the agency_driver tool
#   Activity:   nodes/*.md (what each step does)
#
# Agent interaction (via the workflow tool):
#   workflow cli           → { step, skip, pattern, ... }
#   workflow cli_seed ""   → [{ name, initial_status }]
#
# The workflow tool injects this manifest beside workflow.ncl in Nickel's
# in-memory source cache; direct callers must use the same evaluator seam.
let Vocabulary = import "%inmem_src%:workflow-manifest.json" in
{

  # ── State contract ──────────────────────────────────────────────────────────
  # Contract for workflow state, accepting both JSON strings and Nickel tags.
  # std.enum.TagOrString converts "github" → 'github at contract application.
  # The contract is open (..) to allow extra fields from the agency_driver.

  State = fun raw =>
    raw
      | {
        steps | Array { name | String, status | std.enum.TagOrString, .. },
        forge | std.enum.TagOrString,
        noVcs | Bool,
        # `base` is the resolved branch to branch from, diff against, and
        # target the PR at (enables stacked PRs via --base / --stack).
        # Written by sync; read by vcs_read. Empty until sync runs.
        base | String | default = "",
        minimal | Bool,
        review | Bool | default = false,
        # Entry point ID (e.g. "followup", "polish") set by agency_driver init --from.
        # Read by compute_next when steps is empty to start at the entry point
        # instead of always defaulting to "sync". Empty or "default" → "sync".
        from | String | default = "",
        task | String | default = "",
        active | String | default = "idle",
        status | std.enum.TagOrString | default = 'idle,
        # Forge capability booleans — written by sync (which calls
        # the forge tool's supports operation for each op nodes branch on). Nodes and
        # skip predicates branch on these instead of on the forge string, so
        # the forge → supported-ops map lives in one place (the forge tool's
        # capability table). Only ops with readers are pre-computed;
        # pr-view/pr-edit are trusted to follow pr-create. When #10 lands,
        # only the forge tool's table + dispatch arms change.
        supportsPrCreate | Bool | default = false,
        supportsPrComment | Bool | default = false,
        supportsIssueView | Bool | default = false,
        supportsPrChecks | Bool | default = false,
        ..
      },

  # Normalize imported JSON to State contract.
  # Usage: normalize_state (import ".do-results.json")
  normalize_state | not_exported = State,

  # ── Step definitions ───────────────────────────────────────────────────────
  # Each step: { pattern, pattern_config, next, skip_when, requires, instructions }
  #   pattern:        which retry/parallel shape to use
  #   pattern_config: configuration for that pattern
  #   next:           static string or function(state) → next step name
  #   skip_when:      function(state) → Bool
  #   requires:       data this step needs from prior steps (declarative)
  #   instructions:   path to node file

  Steps = {
    sync = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "research",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/sync.md",
    },

    research = {
      pattern = 'one-shot,
      pattern_config = {},
      next | not_exported = fun state =>
        if state.review then "plan-approval" else "branch",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/research.md",
    },

    plan-approval = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "branch",
      skip_when | not_exported = fun state => !state.review,
      requires = ["research.plan"],
      instructions = "nodes/plan-approval.md",
    },

    branch = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "implement",
      skip_when | not_exported = fun state => state.noVcs,
      requires = ["sync.base"],
      instructions = "nodes/branch.md",
    },

    implement = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "check",
      skip_when | not_exported = fun state => false,
      requires = ["research.plan"],
      instructions = "nodes/implement.md",
    },

    check = {
      pattern = 'check-loop,
      pattern_config = {
        max_attempts = 3,
        flaky_classification = false,
        flaky_budget = 0,
        loop_artifacts = 'none,
        coverage_check = false,
        rerun_on_new_commit = false,
      },
      next | not_exported = fun state =>
        if state.minimal then "fmt" else "docs",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/check.md",
    },

    docs = {
      pattern = 'check-loop,
      pattern_config = {
        max_attempts = 3,
        flaky_classification = false,
        flaky_budget = 0,
        loop_artifacts = 'none,
        coverage_check = false,
        rerun_on_new_commit = false,
      },
      next = "fmt",
      skip_when | not_exported = fun state => state.minimal,
      requires = [],
      instructions = "nodes/docs.md",
    },

    fmt = {
      pattern = 'one-shot,
      pattern_config = {},
      next | not_exported = fun state =>
        if state.noVcs then "hickey-lowy" else "commit",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/fmt.md",
    },

    commit = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "hickey-lowy",
      skip_when | not_exported = fun state => state.noVcs,
      requires = [],
      instructions = "nodes/commit.md",
    },

    hickey-lowy = {
      pattern = 'fanout-fix,
      pattern_config = {
        cross_validate = true,
      },
      next = "police",
      skip_when | not_exported = fun state => state.minimal,
      requires = ["diff", "research.context"],
      instructions = "nodes/hickey-lowy.md",
    },

    police = {
      pattern = 'check-loop,
      pattern_config = {
        max_attempts = 3,
        flaky_classification = false,
        flaky_budget = 0,
        loop_artifacts = 'commit-per-fix,
        coverage_check = false,
        rerun_on_new_commit = false,
      },
      next = "test",
      skip_when | not_exported = fun state => state.minimal,
      requires = ["diff"],
      instructions = "nodes/police.md",
    },

    test = {
      pattern = 'check-loop,
      pattern_config = {
        max_attempts = 4,
        flaky_classification = false,
        flaky_budget = 0,
        loop_artifacts = 'commit-per-fix,
        coverage_check = true,
        rerun_on_new_commit = false,
      },
      next = "create-pr",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/test.md",
    },

    create-pr = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "ci",
      skip_when | not_exported = fun state =>
        state.noVcs || !state.supportsPrCreate,
      requires = [],
      instructions = "nodes/create-pr.md",
    },

    ci = {
      pattern = 'check-loop,
      pattern_config = {
        max_attempts = 5,
        flaky_classification = true,
        flaky_budget = 3,
        loop_artifacts = 'commit-per-fix,
        coverage_check = false,
        rerun_on_new_commit = true,
      },
      next = "evidence",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/ci.md",
    },

    evidence = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "done",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/evidence.md",
    },

    done = {
      pattern = 'one-shot,
      pattern_config = {},
      next = "",
      skip_when | not_exported = fun state => false,
      requires = [],
      instructions = "nodes/done.md",
    },
  },


  # ── Minimal skips (omitted from todo list entirely) ────────────────────────

  MinimalSkips = ["docs", "hickey-lowy", "police", "evidence"],
  ReviewSkips = ["plan-approval"],

  # ── Helper functions ───────────────────────────────────────────────────────

  # Get last element of array, or fallback
  get_last | not_exported = fun arr fallback =>
    if std.array.length arr == 0 then
      fallback
    else
      std.array.last arr,

  # Check if a step should be skipped given current state
  should_skip
    | not_exported
    | doc m%"
    Returns whether a step's `skip_when` predicate fires for the given state.

    ## Examples

    ```nickel
    should_skip "branch" { active = true, status = 'running, steps = [], noVcs = true, minimal = false, review = false, forge = 'github, task = "test" }
    # => true

    should_skip "docs" { active = true, status = 'running, steps = [], noVcs = false, minimal = true, review = false, forge = 'github, task = "test" }
    # => true

    should_skip "create-pr" { active = true, status = 'running, steps = [], noVcs = false, minimal = false, review = false, forge = 'bitbucket, supportsPrCreate = false, supportsPrComment = false, supportsIssueView = false, supportsPrChecks = false, task = "test" }
    # => true

    should_skip "evidence" _test_state
    # => false

    should_skip "ci" { active = true, status = 'running, steps = [], noVcs = true, minimal = false, review = false, forge = 'github, task = "test" }
    # => false
    ```
  "%
    = fun step_name state =>
      let step_def = Steps."%{step_name}" in
      step_def.skip_when state,

  # Get next step name (resolves function or returns static string)
  get_next
    | not_exported
    | doc m%"
    Returns the next step name after the given step, resolving dynamic transitions.

    ## Examples

    ```nickel
    get_next "check" { active = true, status = 'running, steps = [], noVcs = false, minimal = true, review = false, forge = 'github, task = "test" }
    # => "fmt"

    get_next "research" { active = true, status = 'running, steps = [], noVcs = false, minimal = false, review = true, forge = 'github, task = "test" }
    # => "plan-approval"

    get_next "fmt" { active = true, status = 'running, steps = [], noVcs = true, minimal = false, review = false, forge = 'github, task = "test" }
    # => "hickey-lowy"
    ```
  "%
    = fun step_name state =>
      let step_def = Steps."%{step_name}" in
      if std.is_function step_def.next then
        step_def.next state
      else
        step_def.next,

  # Whether --minimal omits a step from both cli routing and todo seeding.
  is_minimal_omission | not_exported = fun step_name state =>
    state.minimal && std.array.any (fun skipped => skipped == step_name) MinimalSkips,

  # Follow graph edges until reaching a step present in a minimal run.
  next_runnable | not_exported = fun step_name state =>
    if step_name == "" then
      ""
    else if is_minimal_omission step_name state then
      next_runnable (get_next step_name state) state
    else
      step_name,

  # Terminal workflow status wins; otherwise resume unfinished steps.
  compute_next | not_exported = fun state =>
    if state.status == 'failed || state.status == 'completed then
      ""
    else
      let last_step = get_last state.steps { name = "", status = 'pending } in
      if last_step.name == "" then
        next_runnable (resolve_entry state.from) state
      else if last_step.status == 'failed then
        "done"
      else if last_step.status == 'passed || last_step.status == 'skipped then
        next_runnable (get_next last_step.name state) state
      else
        last_step.name,

  # Resolve an entry point ID to its declared starting step.
  # Empty input uses the manifest default. Any other missing ID is a Nickel
  # evaluation error rather than an implicit restart at sync.
  resolve_entry
    | not_exported
    | doc m%"
    Maps a declared entry point ID to its starting step name.

    ## Examples

    ```nickel
    resolve_entry "followup"
    # => "implement"

    resolve_entry "polish"
    # => "hickey-lowy"

    resolve_entry "ci-only"
    # => "ci"
    ```
  "%
    = fun from =>
      if from == "" || from == null then
        Vocabulary.entryPoints.default
      else
        Vocabulary.entryPoints."%{from}",
  # Seed the step list for todo UI given a --from entry point and state.
  # Returns: [{ name, initial_status }]
  #   initial_status: 'completed for pre-steps, 'pending for the rest
  #   MinimalSkips steps are omitted entirely when state.minimal is true
  #   (--minimal was passed); otherwise they're included as normal steps.
  seed_steps | not_exported = fun from state =>
    let start = resolve_entry from in
    (
      std.array.fold_left
        (fun acc step_name =>
          let is_start = step_name == start in
          let is_minimal = is_minimal_omission step_name state in
          let is_review = std.array.any (fun s => s == step_name) ReviewSkips in
          let now_reached = acc.reached || is_start in
          if is_minimal || (is_review && !state.review) then
            { list = acc.list, reached = now_reached }
          else
            {
              list =
                acc.list
                @ [
                  {
                    name = step_name,
                    initial_status = if !acc.reached && !is_start then 'completed else 'pending,
                  }
                ],
              reached = now_reached,
            }
        )
        { list = [], reached = false }
        Vocabulary.steps
    ).list,

  # ── CLI output ─────────────────────────────────────────────────────────────
  # Called by the agent: nickel eval workflow.ncl --field cli --arg "$state_json"
  # Returns: { step, skip, pattern, instructions, requires, pattern_config }
  #   or { done = true } when workflow is complete

  cli
    | not_exported
    | doc m%"
    Returns the next step to execute given current state.

    ## Examples

    ```nickel multiline
    cli _test_state
    # => { step = "sync", skip = false, pattern = 'one-shot, instructions = "nodes/sync.md", requires = [], pattern_config = {} }
    cli { active = true, status = 'running, steps = [], noVcs = false, minimal = false, review = false, forge = 'github, from = "polish", task = "test" }
    # => { step = "hickey-lowy", skip = false, pattern = 'fanout-fix, instructions = "nodes/hickey-lowy.md", requires = ["diff", "research.context"], pattern_config = { cross_validate = true } }
    ```
  "%
    = fun state =>
      let next_step = compute_next state in
      if next_step == "" then
        { done = true }
      else
        let step_def = Steps."%{next_step}" in
        let skip_val = step_def.skip_when state in
        {
          step = next_step,
          skip = skip_val,
          pattern = step_def.pattern,
          instructions = step_def.instructions,
          requires = step_def.requires,
          pattern_config = step_def.pattern_config,
        },

  # ── Seed CLI: returns the full step list for todo UI initialization ────────

  cli_seed
    | not_exported
    | doc m%"
    Returns the seeded step list for todo UI initialization.

    `_test_state` has `minimal = false` and `review = false`, so every
    non-review step is emitted. When `state.minimal = true`, the four
    MinimalSkips steps (`docs`, `hickey-lowy`, `police`, `evidence`) are
    dropped from both the seeded list and CLI routing.

    ## Examples

    ```nickel multiline
    cli_seed "" _test_state
    # => [{ name = "sync", initial_status = 'pending }, { name = "research", initial_status = 'pending }, { name = "branch", initial_status = 'pending }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]

    cli_seed "followup" _test_state
    # => [{ name = "sync", initial_status = 'completed }, { name = "research", initial_status = 'completed }, { name = "branch", initial_status = 'completed }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]

    cli_seed "polish" _test_state
    # => [{ name = "sync", initial_status = 'completed }, { name = "research", initial_status = 'completed }, { name = "branch", initial_status = 'completed }, { name = "implement", initial_status = 'completed }, { name = "check", initial_status = 'completed }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'completed }, { name = "commit", initial_status = 'completed }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]

    cli_seed "" { active = true, status = 'running, steps = [], noVcs = false, minimal = false, review = true, forge = 'github, task = "test" }
    # => [{ name = "sync", initial_status = 'pending }, { name = "research", initial_status = 'pending }, { name = "plan-approval", initial_status = 'pending }, { name = "branch", initial_status = 'pending }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "docs", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "hickey-lowy", initial_status = 'pending }, { name = "police", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "evidence", initial_status = 'pending }, { name = "done", initial_status = 'pending }]

    cli_seed "" { active = true, status = 'running, steps = [], noVcs = false, minimal = true, review = false, forge = 'github, task = "test" }
    # => [{ name = "sync", initial_status = 'pending }, { name = "research", initial_status = 'pending }, { name = "branch", initial_status = 'pending }, { name = "implement", initial_status = 'pending }, { name = "check", initial_status = 'pending }, { name = "fmt", initial_status = 'pending }, { name = "commit", initial_status = 'pending }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "done", initial_status = 'pending }]

    cli_seed "polish" { active = true, status = 'running, steps = [], noVcs = false, minimal = true, review = false, forge = 'github, task = "test" }
    # => [{ name = "sync", initial_status = 'completed }, { name = "research", initial_status = 'completed }, { name = "branch", initial_status = 'completed }, { name = "implement", initial_status = 'completed }, { name = "check", initial_status = 'completed }, { name = "fmt", initial_status = 'completed }, { name = "commit", initial_status = 'completed }, { name = "test", initial_status = 'pending }, { name = "create-pr", initial_status = 'pending }, { name = "ci", initial_status = 'pending }, { name = "done", initial_status = 'pending }]
    ```
  "%
    = fun from state =>
      seed_steps from state,

  # ── Test fixtures ──────────────────────────────────────────────────────────

  # Default state for doc tests
  _test_state = {
    active = true,
    status = 'running,
    steps = [],
    noVcs = false,
    minimal = false,
    review = false,
    forge = 'github,
    supportsPrCreate = true,
    supportsPrComment = true,
    supportsIssueView = true,
    supportsPrChecks = true,
    task = "test",
  },
}
