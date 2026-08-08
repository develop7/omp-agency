# Agency OMP plugin — OMP API adoption backlog

This list maps OMP ExtensionAPI / runtime surfaces the plugin could adopt, with projected UX impact and implementation complexity. Sources: `oh-my-pi/packages/coding-agent/src/extensibility/extensions/types.ts`, `docs/extensions.md`, `docs/skills/authoring-extensions.md`.

## Legend

- **UX impact**: how much it changes the user-visible workflow
- **Complexity**: rough implementation + maintenance cost
- **Status**: not started / partially used / done

---

## 1. Custom LLM tools (`pi.registerTool`)

**What**: Register first-class model-callable tools for workflow actions — e.g. `get_ci_status`, `create_pr`, `append_evidence`, `run_police_pass`.

**Where it lives**: `ExtensionAPI.registerTool` at `types.ts:1175`.

**Potential use in agency**:
- Replace bash-driven `/do` sub-steps with typed, testable tool calls.
- Make failures and retries explicit in the tool contract instead of shell-script heuristics.

**UX impact**: Medium. Users still invoke `/do`, but the agent becomes more reliable and its actions are easier to observe/approve.

**Complexity**: High. Requires:
- Defining tool schemas and execution logic.
- Migrating existing bash orchestration without breaking the current skill flow.
- Handling approval tiers (`read`/`write`/`exec`) correctly.

**Status**: Not started.

---

## 2. Slash commands (`pi.registerCommand`)

**What**: Add explicit user entry points like `/agency-do`, `/agency-talk`, `/evidence`, `/ship`.

**Where it lives**: `ExtensionAPI.registerCommand` at `types.ts:1183`.

**Potential use in agency**:
- Let users trigger agency workflows without remembering skill names.
- Commands can run in `ExtensionCommandContext` with session-control methods.

**UX impact**: Medium. Makes agency feel like native OMP commands rather than hidden behind skills.

**Complexity**: Low-Medium. Mostly wrapping existing skill behavior in command handlers; needs to avoid clashing with built-ins.

**Status**: Not started.

---

## 3. `before_agent_start` event injection

**What**: Inject `/do` plan preamble or `/talk` research context as a custom message before the agent loop starts.

**Where it lives**: `ExtensionAPI.on("before_agent_start")` at `types.ts:1157`.

**Potential use in agency**:
- Auto-inject `.agency/do.md` instructions so users don’t have to mention them.
- Prime the model with the current `/do` workflow state.

**UX impact**: Low-Medium. Makes workflows more consistent; users may not notice explicitly.

**Complexity**: Low. Read project config and append to `BeforeAgentStartEventResult.systemPrompt` or `message`.

**Status**: Not started.

---

## 4. Turn-end / agent-end automation

**What**: Trigger structural reviews (`hickey`, `lowy`) or `code-police` automatically after implementation turns.

**Where it lives**: `ExtensionAPI.on("turn_end")` / `on("agent_end")` at `types.ts:1155-1156`.

**Potential use in agency**:
- Remove the need for the `/do` skill to manually schedule reviewer subagents.
- Enforce quality gates as automatic post-turn hooks.

**UX impact**: Medium. Users get reviews without explicit prompts, but risk of unwanted interruptions.

**Complexity**: Medium. Need to detect when an implementation is “done” vs. still exploring, and avoid duplicate reviews.

**Status**: Not started.

---

## 5. Tool call / tool result policy guards

**What**: Intercept destructive or sensitive tool calls and either block, confirm, or redact.

**Where it lives**: `ExtensionAPI.on("tool_call")` / `on("tool_result")` at `types.ts:1159-1160`.

**Potential use in agency**:
- Block `git push` until `code-police` passes.
- Redact secrets from `read`/`bash` results.
- Prevent `rm -rf` outside of an explicit `/do` workflow.

**UX impact**: Medium-High. Users get clearer guardrails, but approval fatigue if overused.

**Complexity**: Medium. Requires careful policy rules and UI confirmation wiring (`ctx.ui.confirm`).

**Status**: Not started.

## 6. `context` event for automatic `.agency/*.md` injection

**What**: Automatically include project agency config files in the model context.

**Where it lives**: `ExtensionAPI.on("context")` at `types.ts:1154`.

**Potential use in agency**:
- Always load `.agency/do.md`, `.agency/hickey.md`, `.agency/lowy.md`, `.agency/code-police.md` without user prompting.
- Centralize project-specific instructions.

**UX impact**: Low. Users get more consistent behavior without manual steps.

**Complexity**: Low. Read files and append `messages` to `ContextEventResult`.

**Status**: Not started.

---

## 7. `input` event routing

**What**: Detect `/do`, `/talk`, `/agency-*` typed into the input and route or rewrite before normal prompt flow.

**Where it lives**: `ExtensionAPI.on("input")` at `types.ts:1161`.

**Potential use in agency**:
- Convert shorthand user input into full skill invocations.
- Validate that required project config exists before starting `/do`.

**UX impact**: Low-Medium. Faster invocation, but must not conflict with OMP’s own slash-command parsing.

**Complexity**: Low. String parsing and early return from `InputEventResult`.

**Status**: Not started.

---

## 8. Dynamic active tool control

**What**: Restrict or expand the active tool set per workflow phase.

**Where it lives**: `ExtensionAPI.setActiveTools()` / `getAllTools()` at `types.ts:1213-1215`.

**Potential use in agency**:
- Read-only tools only during `/talk`.
- Enable `github`, `browser`, `security_scan` only during `/do` shipping phase.
- Disable write tools during structural review passes.

**UX impact**: Low-Medium. Fewer accidental destructive actions in sensitive phases.

**Complexity**: Medium. Need phase tracking and safe restoration of previous tool sets.

**Status**: Not started.

---

## 9. Custom messages + renderers for workflow state

**What**: Emit and render `.do-results.json` progress, PR evidence, and reviewer findings as rich custom UI.

**Where it lives**: `ExtensionAPI.sendMessage()` at `types.ts:1197`, `registerMessageRenderer()` at `types.ts:1191`.

**Potential use in agency**:
- Render the `/do` progress ledger visually instead of as raw JSON.
- Show hickey/lowy findings as collapsible sections.
- Embed PR evidence screenshots inline.

**UX impact**: High. Makes workflow state immediately scannable.

**Complexity**: High. Requires designing TUI components and keeping renderer code stable across OMP updates.

**Status**: Not started.

---

## 10. Shared event bus for cross-extension coordination

**What**: Use `pi.events` to let multiple agency extensions communicate.

**Where it lives**: `ExtensionAPI.events` at `types.ts:1171`.

**Potential use in agency**:
- Split agency into smaller extensions: workflow, guardrails, evidence.
- Let the evidence extension react to `/do` completion signals.

**UX impact**: Low. Architectural benefit, not user-facing.

**Complexity**: Medium. Increases the plugin’s surface area and coordination logic.

**Status**: Not started.

---

## 11. Programmatic model selection via `ctx.models`

**What**: Pick cheaper/faster models for subagent passes without manual `modelRoles.task` config.

**Where it lives**: `ExtensionContext.models` at `types.ts:1018`.

**Potential use in agency**:
- Run `elegance` / `fact-check` on a smaller model.
- Use a stronger model for `hickey` / `lowy` reviews.
- Auto-select a contrasting family for cross-checks.

**UX impact**: Medium. Faster/cheaper subagent runs, less config fiddling.

**Complexity**: Medium. Requires mapping task types to model families and respecting user overrides.

**Status**: Not started.

---

## 12. Persistent memory via `ctx.memory`

**What**: Store cross-PR project memory instead of relying only on GitHub issues.

**Where it lives**: `ExtensionContext.memory` at `types.ts:1041`.

**Potential use in agency**:
- Remember lessons from previous `/do` runs in the same repo.
- Track recurring hickey/lowy findings across PRs.
- Persist project-specific volatility declarations.

**UX impact**: Medium. Long-lived projects get better recommendations over time.

**Complexity**: High. Memory design is easy to get wrong; needs clear scope, eviction, and privacy boundaries.

**Status**: Not started.

---

## 13. MCP notification bridge

**What**: Listen to MCP server notifications and turn them into session steers.

**Where it lives**: `ExtensionAPI.on("mcp_notification")` at `types.ts:1165`.

**Potential use in agency**:
- Bridge CI MCP notifications into the `/do` CI step.
- Drive browser devtools MCP for PR evidence capture.
- React to external build/test events.

**UX impact**: Medium. Enables tighter integration with external systems.

**Complexity**: Medium-High. Depends on external MCP server availability and notification semantics.

**Status**: Not started.

---

## Currently used

### `session_stop` extension (`stop-guard`)

**What**: Blocks agent stop mid-`/do` by reading `.do-results.json`.

**Where it lives**: `src/stop-guard.ts:6`, `package.json: "omp.extensions"`.

**UX impact**: High. Prevents accidental abandonment of long-running workflows.

**Complexity**: Low. Already implemented.

**Status**: Done.

---

## Recommended order

1. **Low-hanging UX wins**: `context` injection (#6), `input` routing (#7), `before_agent_start` preamble (#3).
2. **Reliability**: tool-call guards (#5), dynamic tool control (#8), turn-end automation (#4).
3. **Native feel**: slash commands (#2), custom messages/renderers (#9), custom tools (#1).
4. **Long-term architecture**: event-bus split (#10), `ctx.models` selection (#11), `ctx.memory` (#12), MCP bridge (#13).
