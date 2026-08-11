# Agency OMP plugin — source-audited API adoption backlog

This backlog audits the agency plugin against `@oh-my-pi/pi-coding-agent` **v17.2.12** at commit [`45e12e5`](https://github.com/can1357/oh-my-pi/tree/45e12e5bb758198a920c6070e7e64cb33b21beac). “Feasible” means the OMP API can support the behavior end to end; it does not by itself mean agency should add it.

Agency’s current control plane remains the `/do` skill plus `skills/do/scripts/do-driver`, `do-results`, and Nickel. The extension currently contributes one `session_stop` guard in `src/stop-guard.ts`. New extension surfaces must adapt that existing workflow rather than create a second TypeScript state machine.

## Status vocabulary

- **Planned** — useful, source-verified, and has a bounded implementation path.
- **Conditional** — feasible, but only after the named trigger or prerequisite exists.
- **Deferred** — no current agency problem justifies the maintenance cost.
- **Done** — the intended behavior already exists.
- **Rejected** — technically possible or partly possible, but conflicts with agency’s design or duplicates an existing mechanism.
- **Merged** — retain this section as an API audit, but implement it through another item rather than as a separate abstraction.

## Decision matrix

| # | OMP surface | API feasibility | Agency disposition |
|---|---|---|---|
| 1 | `registerTool` | Feasible | **Planned, narrowly**: typed adapters over the existing `/do` scripts; no second workflow engine |
| 2 | `registerCommand` | Feasible | **Deferred**: OMP has no command-to-skill delegation primitive, and `/do` already owns the UX |
| 3 | `before_agent_start` | Feasible | **Planned**: one bounded, model-visible workflow-state message per agent run |
| 4 | `turn_end` / `agent_end` / `session_stop` | Feasible | **Partly done**: keep `session_stop`; reject hidden CI/test orchestration in lifecycle hooks |
| 5 | `mcp_notification` + `sendMessage` | Feasible | **Deferred** until a concrete producer, method, schema, and delivery policy exist |
| 6 | `tool_call` + `context` | Feasible | **Merged/conditional**: validate workflow tools at their source; add a global guard only for a real cross-tool invariant; context belongs to #3 |
| 7 | `input` | Interactive-only | **Rejected** as an intent classifier; reserve for explicit, deterministic syntax only |
| 8 | `getActiveTools` / `getAllTools` / `setActiveTools` | Feasible | **Deferred** until measurement shows a tool-selection problem |
| 9 | custom messages and renderers | Feasible in TUI | **Conditional**: begin with tool `renderCall` / `renderResult`; add a message renderer only for out-of-tool events |
| 10 | `pi.events` | Feasible within one extension runtime | **Rejected now**: direct calls are simpler with one agency extension; it is not a cross-session bus |
| 11 | `ctx.models` + `pi.setModel` | Static routing already works; dynamic child routing is constrained but feasible | **Static goal done; dynamic policy deferred** |
| 12 | `ctx.memory` | Search/save/status only | **Rejected** for cross-PR agency memory; conflicts with the documented product design and lacks deletion/eviction |
| 13 | MCP notification bridge | Feasible for server-initiated notifications | **Merged into #5**; not a bridge for ordinary MCP tool results |

---

## 1. Custom LLM tools (`pi.registerTool`)

**What OMP provides**

A registered tool has a schema, approval tier, load mode, abort/progress-aware `execute`, session lifecycle callback, and optional call/result renderers. Extension tools default to discoverable loading, and an omitted approval tier defaults to `exec`. `ctx.invokeTool` is not a general tool dispatcher: it delegates only to the native built-in with the **same name** when an extension re-registers that built-in.

**Agency implementation**

Keep `do-results`, `do-driver`, and Nickel as the workflow engine. Add typed tools only where they replace fragile shell-shaped model calls:

1. Add a read-only workflow snapshot command to the existing script boundary, or a single thin reader that returns the same `.do-results.json` data without reinterpreting the state machine.
2. Register namespaced tools such as a read-only `agency_workflow_status` and mutation operations corresponding exactly to `do-driver start` and `do-driver end`.
3. Give each mutation a schema that makes invalid states unrepresentable: `start` requires a step name; `end` requires `passed | failed | skipped`, verification text, and an optional reason.
4. Invoke the existing scripts; do not port their transition rules into the extension. Return concise model-facing text plus structured `details` for future rendering.
5. Propagate non-zero exit status as a tool error. Do not silently fall back to the old shell call after a caller has migrated.
6. Migrate the `/do` skill one operation at a time, then remove the corresponding direct shell instruction. One operation must never have two supported mutation paths in the final state.

Do **not** create agency wrappers for GitHub, browser, security scanning, subagent spawning, or generic command execution: OMP already owns those capabilities. `run_police_pass` also remains orchestration in the skill, not a mechanical tool.

**Why this order matters**

The current skill explicitly initializes and advances workflow state through shell commands, and `do-results` already enforces transition invariants such as “one pending step.” A second TypeScript `WorkflowState` class would duplicate that authority. The extension is an adapter, not a replacement engine.

**UX impact**: Medium. Fewer malformed state mutations and clearer tool errors; the visible `/do` workflow remains the same.

**Complexity**: Medium, not high, if the tools remain thin adapters. High if they absorb orchestration, forge behavior, or review policy.

**Status**: **Planned, after the script boundary exposes a stable read contract.**

**Sources**

- Agency workflow calls and result persistence: `skills/do/SKILL.md:28-45`, `skills/do/SKILL.md:79-89`, `skills/do/scripts/do-results:4-18`, `skills/do/scripts/do-results:41-94`.
- OMP tool contract: [`types.ts:547-590`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L547-L590), [`types.ts:1220-1232`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1220-L1232).
- Same-tool-only native delegation: [`types.ts:472-490`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L472-L490), [`wrapper.ts:52-81`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/wrapper.ts#L52-L81).

---

## 2. Native slash commands (`pi.registerCommand`)

**What OMP provides**

Extensions can register local commands with argument completion and an async handler. Built-in names are reserved. Across extensions, later-loaded command registrations win. The interactive submit path runs the `input` hook first, then built-ins, skills, shell/Python handling, and finally local extension commands.

**Critical constraint**

A command handler has session-control methods, but no `invokeSkill` method. Calling `pi.sendUserMessage("/do …")` is not delegation: `sendUserMessage` deliberately calls `prompt(..., { expandPromptTemplates: false })`, bypassing command and template expansion. Registering another `/do` also has mode-dependent collision behavior because the interactive frontend consumes a known skill before it reaches the extension command path.

**Agency implementation**

Do not replace `/do` or `/talk` with extension commands. If item #1 eventually extracts a callable workflow service, a namespaced command such as `/agency-do` may call that same service and then start the model turn. Until then, it would duplicate the skill or rely on a false delegation path.

A small read-only `/agency-status` command is only worthwhile if it can produce useful output in both TUI and headless modes; `ctx.ui` alone does not satisfy that requirement.

**UX impact**: Low today. The existing skills are already discoverable and explicit.

**Complexity**: Low API cost, medium product cost because command/skill behavior must remain identical.

**Status**: **Deferred; blocked on a shared callable workflow service, not on OMP API support.**

**Sources**

- Command registration and context: [`types.ts:495-528`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L495-L528), [`types.ts:1228-1243`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1228-L1243).
- Interactive routing order: [`input-controller.ts:675-775`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/modes/controllers/input-controller.ts#L675-L775), [`input-controller.ts:770-842`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/modes/controllers/input-controller.ts#L770-L842).
- `sendUserMessage` bypasses command expansion: [`agent-session.ts:6045-6078`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/session/agent-session.ts#L6045-L6078).

---

## 3. Per-turn workflow context (`before_agent_start`)

**What OMP provides**

`before_agent_start` receives the submitted prompt, images, and effective system prompt. A handler may add a custom message or replace the system prompt for that run. Handler results are awaited and chained.

**Agency implementation**

Use one pure `renderWorkflowContext(snapshot)` function and one `before_agent_start` handler:

1. Read the stable workflow snapshot from the existing `/do` state boundary.
2. If no run is active, return nothing.
3. Otherwise return one bounded, agent-attributed custom message containing the active step, workflow mode (`review`, `noVcs`, `minimal`), and the next valid action.
4. Set `display: false`; this is model context, not a second progress UI.
5. Cap the payload and omit completed-step history already present in tool results/session history.

Do not replace `systemPrompt` for ordinary workflow context. In OMP, a `before_agent_start` system-prompt replacement becomes a turn override and marks the base xdev catalog as not delivered for that turn. A custom message is the narrower operation.

Do not also inject the same state through `context` or `input`. `context` runs at provider-request frequency; `input` owns deterministic input syntax. Duplicate injection creates two ordering rules and unnecessary context growth.

**UX impact**: Medium. Resume and phase constraints become visible to the model without requiring it to rediscover `.do-results.json`.

**Complexity**: Low once the workflow snapshot has one stable read contract.

**Status**: **Planned.**

**Sources**

- Event and result contract: [`types.ts:678-686`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L678-L686), [`types.ts:1063-1068`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1063-L1068).
- Turn override behavior: [`agent-session.ts:5360-5400`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/session/agent-session.ts#L5360-L5400).
- Generic extension handlers are bounded and errors are isolated: [`runner.ts:81-115`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/runner.ts#L81-L115), [`runner.ts:925-973`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/runner.ts#L925-L973).

---

## 4. Lifecycle automation (`turn_end`, `agent_end`, `session_stop`)

**What OMP provides**

- `turn_end` fires for every model turn and includes that turn’s tool results.
- `agent_end` fires when an agent loop ends; `willContinue` distinguishes an internally scheduled continuation from a user-visible settle.
- `session_stop` runs immediately before the main turn settles and can request one continuation with model-visible context.

**Agency implementation**

Keep lifecycle control narrow:

1. Retain the existing `session_stop` guard. Move only its state reading behind the same stable snapshot boundary used by items #1 and #3.
2. Continue only when `/do` state says the workflow is active. Include the current step in `additionalContext` when available.
3. Do not launch tests, CI, reviewers, or PR operations from `turn_end` or `agent_end`. Those are explicit Nickel workflow nodes with persisted start/end evidence; hidden lifecycle automation would create a second scheduler.
4. If `agent_end` is later used for observation, ignore events with `willContinue: true` and never mutate workflow state there.
5. Avoid `turn_end` for progress state: one `/do` step can span many turns, so turn boundaries are not workflow boundaries.

**UX impact**: High for the existing stop guard; low for additional observation hooks.

**Complexity**: Existing guard is low. Hidden task automation would be high and is rejected.

**Status**: **`session_stop` continuation is done; state-reader cleanup is planned; additional automation is rejected.**

**Sources**

- Current guard: `src/stop-guard.ts:5-19`.
- Existing explicit workflow sequencing: `skills/do/SKILL.md:38-45`, `skills/do/SKILL.md:79-89`.
- Lifecycle event contracts: [`shared-events.ts:193-220`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/shared-events.ts#L193-L220), [`shared-events.ts:97-109`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/shared-events.ts#L97-L109), [`shared-events.ts:379-391`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/shared-events.ts#L379-L391).

---

## 5. External notification adapter (`mcp_notification` + `sendMessage`)

**What OMP provides**

Every server-initiated MCP JSON-RPC notification reaches the extension after OMP handles known list/update methods. The event contains the raw configured server name, method, and opaque params. `pi.sendMessage` can deliver a custom message as a steer, follow-up, or next-turn message.

**Required contract before implementation**

A concrete source must define all of:

- exact `server` and `method` allowlist;
- a versioned params schema;
- event identity/deduplication key;
- main-session versus child-session policy;
- delivery mode (`steer`, `followUp`, or `nextTurn`);
- rate limit/debounce behavior;
- whether the event is model-visible or UI-only.

Only then add a source-specific adapter. Keep parsing and validation local to that source; do not start with a generic `ExternalNotificationRouter` abstraction. Ignore ordinary child sessions unless duplicate delivery is explicitly wanted, because subagent sessions can install their own notification listeners.

Use agent-attributed custom messages for external system facts; do not make them look like user input. Never trigger a new turn for a status-only event.

**UX impact**: Potentially high for a real CI or review event producer; zero without one.

**Complexity**: Medium per source. A generic router would add complexity without a contract.

**Status**: **Deferred until a producer and schema exist.**

**Sources**

- Notification payload and timing: [`types.ts:776-789`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L776-L789).
- Delivery modes: [`types.ts:1270-1293`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1270-L1293).
- MCP fan-out and bounded startup buffers: [`sdk.ts:3738-3761`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/sdk.ts#L3738-L3761).

---

## 6. Tool-call guards and request context (`tool_call`, `context`)

These are two different concerns and should not share one “policy engine.”

### Tool-call guards

A `tool_call` handler can block execution or replace the raw input. For model-issued calls, revised input is revalidated and becomes the input shown for approval, persistence, and execution. Guard errors and timeouts fail closed.

Prefer validation inside the item #1 workflow tool for workflow-local invariants. Add one global `tool_call` handler only when a rule genuinely spans multiple tools—for example, a future invariant that no tool may mutate a protected workflow artifact outside the canonical adapter. Keep that handler local and deterministic; no network calls, model calls, or shell parsing.

A tool hook is policy enforcement, not a sandbox. Bash and mounted devices have distinct input shapes, so a broad “block dangerous commands” rule would be brittle and misleading.

### Request context

The `context` event receives a deep copy of messages about to be sent and may replace that list. It is appropriate for request-time redaction or normalization that must run before every provider request. It is not needed for the initial workflow-state use case; item #3’s single `before_agent_start` message is sufficient and cheaper.

**UX impact**: High only for a precise guard; otherwise invisible.

**Complexity**: Low for one exact invariant, high for a generic rule table.

**Status**: **Workflow-local validation merges into #1; global guards are conditional; context injection merges into #3.**

**Sources**

- Tool-call payload: [`hooks/types.ts:303-317`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/hooks/types.ts#L303-L317).
- Block/revision and approval ordering: [`shared-events.ts:295-319`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/shared-events.ts#L295-L319).
- Fail-closed timeout behavior: [`runner.ts:1084-1124`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/runner.ts#L1084-L1124).
- Context hook contract: [`shared-events.ts:185-190`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/shared-events.ts#L185-L190), [`types.ts:1031-1034`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1031-L1034).

---

## 7. Input routing (`input`)

**What OMP provides**

The hook can consume input or replace its text/images, but it is an **interactive-mode** event. It runs before built-in, skill, shell, Python, and extension-command routing, so a bug can swallow or rewrite every local command.

**Agency decision**

Do not infer “chatty means `/talk`” or “execution intent means `/do`.” That is a second, hidden intent classifier in front of explicit user commands, and it changes behavior in TUI but not headless/RPC flows.

The only acceptable future use is deterministic syntax with no semantic guessing: an exact alias, a project-specific prefix, or image normalization. The handler must return unchanged input for every unrecognized form.

**UX impact**: Negative for semantic routing; small for an explicit alias.

**Complexity**: Low code cost, high behavioral risk.

**Status**: **Rejected as an intent router; conditional only for explicit syntax.**

**Sources**

- Input event/result contract: [`types.ts:825-831`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L825-L831), [`types.ts:1040-1047`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1040-L1047).
- It runs before command routing: [`input-controller.ts:675-743`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/modes/controllers/input-controller.ts#L675-L743).

---

## 8. Dynamic tool control (`getActiveTools`, `getAllTools`, `setActiveTools`)

**What OMP provides**

Extensions can inspect the current active names, inspect every configured tool with source metadata, and replace the active set by name.

**Agency implementation, if measurement justifies it**

Do not build a phase-to-tool matrix preemptively. OMP already distinguishes essential and discoverable tools, and replacing the active set creates restoration and session-scope obligations.

The first defensible use would be limited to agency-owned tools: keep an agency mutation tool inactive when no `/do` run exists, activate it from a deterministic workflow transition, and restore only the agency-owned names. Do not remove OMP core tools based on prompt classification. Intersect requested names with `getAllTools()` and treat unknown names as a configuration error.

Tool-set selection must remain separate from `tool_call` guard rules: one controls availability; the other decides whether a concrete invocation is permitted.

**UX impact**: Unproven. It may reduce tool noise, but can also make capabilities disappear unexpectedly.

**Complexity**: Medium because state must survive turn/session transitions and child-session extension loading.

**Status**: **Deferred until traces show tool confusion, schema cost, or a concrete agency-owned activation need.**

**Sources**

- Active-tool API: [`types.ts:1304-1315`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1304-L1315).
- Tool load modes and `defaultInactive`: [`types.ts:552-565`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L552-L565).

---

## 9. Custom messages and renderers (`sendMessage`, `registerMessageRenderer`, tool renderers)

**What OMP provides**

A tool can render its own call/result. Separately, an extension can send a persisted custom message and register a renderer keyed by `customType`. Rendering is TUI-only; headless sessions still need complete textual content. Across extensions, renderer lookup takes the first loaded renderer for a type, so agency custom types must be namespaced.

Custom messages are not a free UI side channel: their content is converted into LLM messages. Rich visual state belongs in `details`, while `content` stays concise and model-relevant.

**Agency implementation**

1. Start with `renderCall` / `renderResult` on the item #1 workflow tools. The tool result already has the correct lifecycle, persistence, and model-visible fallback.
2. Add `registerMessageRenderer("agency.workflow-event", …)` only if meaningful workflow events occur outside those tool calls.
3. Emit one versioned event envelope: `{ version, phase, step, status, evidenceSummary }`. Do not create separate message types for tests, CI, reviewers, and PRs unless their rendering actually differs.
4. Keep headless `content` complete; the renderer is enhancement, never the only representation.
5. Do not add a thinking renderer for workflow state. Thinking blocks are a different lifecycle and would couple presentation to model internals.

Inline screenshots are technically possible through the exported TUI `Image` component, which has a default live-image budget of eight. They are not an initial requirement: image-bearing custom messages also enter model/session content, and evidence artifacts or links are cheaper when the model does not need the pixels.

**UX impact**: Medium for compact state cards; high only if the existing transcript is demonstrably hard to scan.

**Complexity**: Low-medium for tool renderers; high for image-aware custom components and cross-mode parity.

**Status**: **Conditional after #1; tool renderers first, custom message renderer second.**

**Sources**

- Tool and message renderer contracts: [`types.ts:547-590`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L547-L590), [`types.ts:1085-1093`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1085-L1093), [`types.ts:1265-1293`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1265-L1293).
- Custom messages become LLM content: [`messages.ts:1168-1197`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/session/messages.ts#L1168-L1197).
- Renderer lookup: [`runner.ts:774-780`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/runner.ts#L774-L780).
- TUI images and budget: [`tui/index.ts:1-10`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/tui/src/index.ts#L1-L10), [`image.ts:20-37`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/tui/src/components/image.ts#L20-L37).

---

## 10. Shared event bus (`pi.events`)

**What OMP provides**

All extensions loaded into one `loadExtensions` call share one in-memory `EventBus`. `emit` is fire-and-forget; listeners are error-isolated and async completion is not awaited. A new bus is created when a loader call does not receive one.

**Agency decision**

Agency currently has one extension entry and native lifecycle events already cover its work. Internal functions should call each other directly. Introducing event names, opaque `unknown` payloads, and asynchronous ordering would make local control flow harder to trace.

This bus also does not solve main-agent/subagent coordination: child sessions create/rebind their own extension runtimes. Use `pi.events` only if at least two independently loaded extensions must exchange a same-session notification and neither should depend on the other. At that point, wrap the untyped channel in one versioned payload codec.

**UX impact**: None by itself.

**Complexity**: Low API cost, unnecessary structural cost now.

**Status**: **Rejected until a concrete cross-extension, same-session producer/consumer pair exists.**

**Sources**

- Event bus API: [`types.ts:1382-1387`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1382-L1387).
- Runtime behavior: [`event-bus.ts:1-38`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/utils/event-bus.ts#L1-L38).
- Per-loader creation and sharing: [`loader.ts:412-438`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/loader.ts#L412-L438).

---

## 11. Programmatic model selection (`ctx.models`, `pi.setModel`)

**What already works**

Static task routing is already the correct agency mechanism. OMP resolves task models in this order: caller override, `task.agentModelOverrides`, agent frontmatter, then active/session fallback. Agency’s Hickey and Lowy agents declare `model: "@task"`; the read-only code-police passes use the bundled `scout` agent. The original “strong reviewer versus smaller mechanical audit” goal therefore does not require an extension.

**What dynamic routing can do**

`ctx.models` is read-only but can list authenticated models, resolve role aliases, inspect the current child model, and compare families. `pi.setModel` mutates the current session. Ordinary task children preload extensions, append a `session_init` record, initialize their extension runner, and emit `session_start` before the first prompt. A child-loaded agency extension can therefore select a model in `session_start`, before OMP builds that prompt’s model-specific system context.

A defensible dynamic policy would:

1. Handle `session_start` only in ordinary child sessions whose `session_init.agent` is on an explicit allowlist.
2. Act only when `session_init.modelRole` is the policy-owned role (for example `@task`); concrete or different-role operator overrides win.
3. Resolve candidates from configured OMP role aliases, not hard-coded model IDs.
4. Compare each candidate family with the family of `session_init.resolvedModel`, so the reference does not change after switching.
5. No-op when the current model is already the selected candidate; otherwise call `await pi.setModel(candidate)` once.
6. No-op when no authenticated candidate exists or `setModel` returns false.

**Constraints**

- The public `task` wire schema has no per-item `model` field, so ordinary callers cannot request this directly.
- Restricted children omit preloaded extensions, so the handler cannot cover every child mode.
- `session_init` records `agent`, `modelRole`, and `resolvedModel`, but not the full source provenance of the winning selector. An extension can respect concrete/different-role overrides, but cannot distinguish every way an operator may have selected the same role alias.
- Agency currently has no specified candidate ranking or evidence that cross-family routing improves reviews enough to justify hidden model mutation.

**UX impact**: Static routing already delivers the main cost/quality benefit. Dynamic routing may improve review independence, but can make model choice less predictable.

**Complexity**: Low for static configuration; medium-high for a transparent dynamic policy.

**Status**: **Static goal done. Dynamic contrasting-family routing is feasible for ordinary children but deferred pending an explicit policy and measurement.**

**Sources**

- Existing agency routing: `agents/hickey.md:1-5`, `agents/lowy.md:1-5`, `skills/code-police/SKILL.md:82-88`, `README.md:61-65`.
- Bundled `scout` resolves through `@smol`: [`scout.md:1-8`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/prompts/agents/scout.md#L1-L8).
- Core model precedence: [`structured-subagent.ts:278-298`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/task/structured-subagent.ts#L278-L298), [`model-resolver.ts:1107-1153`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/config/model-resolver.ts#L1107-L1153).
- Model query/set surfaces: [`types.ts:397-425`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L397-L425), [`types.ts:1310-1318`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L1310-L1318).
- Child metadata and extension ordering: [`executor.ts:3039-3046`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/task/executor.ts#L3039-L3046), [`executor.ts:3137-3198`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/task/executor.ts#L3137-L3198), [`executor.ts:3190-3240`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/task/executor.ts#L3190-L3240), [`session-entries.ts:204-222`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/session/session-entries.ts#L204-L222).

---

## 12. Structured memory (`ctx.memory`)

**What OMP provides**

The optional memory facade exposes `status`, `search`, and `save` across the configured backend. Status reports whether the backend is active, writable, searchable, and what scope/banks it uses. The extension facade exposes no update, delete, clear, or eviction operation.

**Agency decision**

Do not add cross-PR memory. Agency explicitly documents that there is no built-in memory across PRs by design: recurring findings should become project rules/configuration, and unresolved work should remain a GitHub issue. Storing volatility declarations or review findings in both `.agency/*.md` and a memory backend would create competing authorities and stale recall.

The missing deletion/eviction surface is an additional blocker for the original proposal’s retention and privacy requirements. Backend-specific capabilities should not be reached around the facade from this plugin.

Retain this item only as a rejected decision record. If the product principle changes, open a new design with ownership, namespace, retention, deletion, and conflict rules before writing code.

**UX impact**: Potentially harmful through stale or cross-project context.

**Complexity**: High because product semantics, not the `save` call, are the hard part.

**Status**: **Rejected.**

**Sources**

- Agency design principle: `README.md:28-40`.
- Memory contract and limits: [`memory-backend/types.ts:16-73`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/memory-backend/types.ts#L16-L73), [`types.ts:454-460`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L454-L460).

---

## 13. MCP notification bridge (`mcp_notification`)

**Verified scope**

This event is a source adapter for item #5, not a separate agency subsystem. It receives **server-initiated notifications**. A normal MCP tool response does not become an `mcp_notification`, so browser/CI/evidence use cases require an MCP server that actually emits a documented notification method.

OMP protects startup with two drop-oldest buffers capped at 100, but this is not a durable queue. Notifications can fan out to parent and child sessions that installed listeners; an agency adapter must explicitly select its session scope and deduplicate externally identified events.

**Implementation trigger**

When a real producer exists, implement its exact `{server, method, params}` adapter under item #5, validate before delivery, and test burst/deduplication behavior. Do not add a generic MCP bridge first.

**UX impact**: High only with a real event-producing server.

**Complexity**: Medium with a stable schema; undefined without one.

**Status**: **Merged into #5 and deferred with it.**

**Sources**

- Event semantics: [`types.ts:776-789`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/extensibility/extensions/types.ts#L776-L789).
- Listener fan-out and bounded startup buffering: [`sdk.ts:3738-3761`](https://github.com/can1357/oh-my-pi/blob/45e12e5bb758198a920c6070e7e64cb33b21beac/packages/coding-agent/src/sdk.ts#L3738-L3761).

---

## Recommended implementation order

1. **Stabilize the existing workflow read boundary**: extend `do-results`/`do-driver` with one machine-readable snapshot contract; make `stop-guard` consume it. The scripts remain the authority.
2. **Per-run context (#3)**: inject one bounded workflow-state message from that snapshot.
3. **Typed workflow adapters (#1)**: migrate direct shell-shaped state calls one operation at a time; preserve the existing engine and evidence format.
4. **Exact guards (#6), only if needed**: validate workflow transitions at the tool boundary; add a global hook only for a real cross-tool invariant.
5. **Rendering (#9), only after typed events exist**: tool renderers first; custom message renderer only for events outside tools.
6. **Optional command UX (#2)**: only after command and skill can call the same workflow service without replaying `/do` text.
7. **Source-triggered work**: implement #5/#13 only when an MCP producer contract exists; implement #8 only after tool traces justify it; experiment with dynamic #11 only after a model policy and success metric exist.
8. **Do not schedule**: semantic input routing (#7), a generic EventBus layer (#10), or cross-PR memory (#12).

## Review-driven boundary decisions

- Do not add generic `WorkflowState`, `PolicyEngine`, `ContextComposer`, `WorkflowStateRenderer`, or `ExternalNotificationRouter` classes. They would shadow existing `/do` script/node responsibilities and bundle unrelated OMP mechanisms.
- Keep the existing scripts as workflow authority; extension code is a thin source adapter.
- Keep tool availability (#8), invocation guards (#6), request context (#3), and rendering (#9) separate. They change for different reasons.
- Prefer pure functions and one handler per event over public “manager” objects. Introduce a module only when two real callers need the same logic.
