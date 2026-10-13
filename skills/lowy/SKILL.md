---
name: lowy
description: Evaluate architecture and module boundaries for volatility-based decomposition using Juval Lowy's framework (from "Righting Software", building on Parnas 1972). Use when reviewing module splits, service boundaries, new abstractions, or any decomposition decision. Trigger on phrases like "where should this boundary be", "how to split this", "module boundaries", "encapsulate change", "volatility", or references to Lowy, Parnas, or "Righting Software". Complements /hickey (interleaved concerns) with a different lens (change encapsulation).

---

# Lowy: Volatility-Based Decomposition Review

The core question: **do boundaries encapsulate axes of change, or just group related functionality?** Sources: Juval Lowy, [*Righting Software*](https://rightingsoftware.org/) (2019), building on Parnas, ["On the Criteria to Be Used in Decomposing Systems into Modules"](https://www.win.tue.nl/~wstomv/edu/2ip30/references/criteria_for_modularization.pdf) (1972).

**Key idea.** Functional decomposition groups code by what it does (UserService, PaymentController); volatility-based decomposition groups by what *changes*, encapsulating each axis behind a stable interface. Lowy's electricity receptacle is the compact analogy: supply-side volatility is hidden behind one stable socket. Functional decomposition maximizes the blast radius of change.

**Two volatility types in business logic**: *sequence* volatility (workflow order changes independently — belongs in orchestrators/Managers) and *activity* volatility (how a step is performed changes independently — belongs in strategies/Engines). Conflating them makes either change ripple into the other.

**Variable vs. volatile.** Not everything that varies is volatile. *"If you cannot clearly state what the volatility is, why it is volatile, and what risk it poses in likelihood and effect, look further."* Adding an attribute to a data model may be variable without being volatile. Decomposing around mere variability produces over-engineered boundaries.

## Scope

The trigger is a starting point, not a frame. Default to **whole-module scope**; cross-file boundary questions and sibling modules are in scope when the question recurs there. Don't let the framing define the scope: if the volatility actually lives elsewhere — the data model, consumer pattern, or sequence/activity split — the redirected finding is the headline.

**The graduation sweep — ask the boundary question in both directions**: did volatility leak *into* a module (containment)? And does the diff create app-local machinery hiding a hard volatility (transport, connection lifetime, reconnection, multiplicity racing user intent) that wants its own receptacle/package (graduation)? Name each candidate's volatility and wanted home as a recorded opportunity, never a blocker; prove-then-extract governs *when*.

## The Evaluation

For every boundary, split, or new abstraction:

### 1. Name the Volatility

Be specific — "the payment provider", not "requirements might change". No concrete axis means the boundary may be arbitrary.

**Project-declared areas of volatility.** Read `.agency/lowy.md` if it exists. Its rows use this schema:

| Area of volatility | What changes | Why volatile (likelihood × effect) | Expected encapsulation |
|--------------------|--------------|------------------------------------|------------------------|

Rows are surviving candidates after the project's variable-vs-volatile screen, not findings and not above review. For each row: (a) re-apply Lowy's bar — state what the volatility is, why it is volatile, and what risk it poses in likelihood and effect — and challenge rows that fail it; (b) audit whether the boundaries under review actually encapsulate the surviving volatilities in one place.

**Check for prior encapsulation.** Search for the canonical receptacle the project already has for this axis: a command palette for "pick a thing", generic dialog for modal interaction, orchestrator for sequence, strategy registry for activity, or one tagged error type for failure modes. A parallel receptacle for an already-encapsulated axis is **duplicated volatility encapsulation**, a first-class finding before any critique inside the new abstraction. "New domain, same kind" duplicates the receptacle, not the volatility. Run this survey when the diff adds a new top-level module or boundary, as indicated by the `vcs_read` tool with `{ args: ["new-files"] }`; pure refactors without new boundaries are exempt.

**Speculative volatility is not volatility** — a scenario counts only if it has happened, is on a roadmap, or is a near-certain consequence of the domain. **Weak volatility may not deserve its own boundary** — ask whether it justifies the cost or folds into an existing one.

### 2. Classify

Is the volatility about **sequence** or **activity**? Also flag *domain decomposition*: boundaries around domain entities (ProjectService, AccountsManager) are functional decomposition in a domain hat.

### 3. Functional vs. Volatility Boundary

Does the boundary exist because the code *does something different*, or because what is behind it *changes independently*? **The naming test**: orchestrators named for the encapsulated volatility (AccountManager — good; BillingManager — bad, the gerund signals functional grouping); engines named for the volatile activity (SearchEngine — good; AccountEngine — bad). If you cannot name the boundary after an axis, it may not encapsulate one.

### 4. Change Blast Radius

Trace a plausible change through the modules; leaking across boundaries means functional decomposition. **Volatility should decrease downward** — the most depended-upon components must be the least volatile. **Check symmetry**: similar modules should show the same calling patterns; an asymmetry, present or absent, flags a missed axis.

### 5. Interface Stability

An interface that changes with the volatility it encapsulates is leaking. **Expose atomic business verbs** (credit, debit, transfer), not implementation operations. An interface mixing `OpenPort`/`ClosePort`/`AdjustBeam` with `ReadCode` jams communication and reading axes behind one contract. Good interfaces are reusable (the tool-hand analogy); implementations never are.

### 6. Reuse Signal

Reuse increases downward through layers; a lower-layer component locked to a single consumer can suggest functionality-tracking. **But a single in-tree consumer is not disqualifying when the interface is stable under the encapsulated axis** — a receptacle with one wire plugged in is still a receptacle. Precedent includes [`@kolu/surface`](https://kolu.dev/blog/surface-framework/) and the kolu#998 graduations, extracted at one consumer. The disqualifying shape is *"the interface mirrors the implementation"*, not *"one importer today"*.

### 6.5 Package Coherence

When an extraction crosses a **package** boundary, the package must read as **one concept, one socket**:

1. **Read the exports list as a new consumer.** One coherent thing, or a topic-bundle? `@kolu/surface` exports `defineSurface`, one coherent entry point. By contrast, `@kolu/solid-xterm@0.1` exported `createXtermWebgl`, `attachXtermStyleSync`, and `createScrollLock` — three internal aspects leaked through three exports. The `@0.2.0` fix ([`4af1c647`](https://github.com/juspay/kolu/commit/4af1c647)) replaced them with one `createSolidXterm(...)` primitive hiding those submodules.
2. **Apply §5's atomic-verb rule at package altitude.** `createX_webgl` / `attachX_style` / `createX_scroll` is three operations on three axes, not one abstraction.
3. **Apply the Surface test.** One entry point per coherent concept, with internal submodules hidden. Exports that pass §5 individually can collectively fail here.
4. **Watch for the "consumer wires it together" smell.** If a consumer imports several exports and composes them by hand, the missing primitive is the composition.

Verdict when it fires: not "don't extract" — **"extract one socket, not three wires."**

### 7. The Almost-Expendable Test

Expensive to change means too big (coupled concerns). Trivially expendable means an unnecessary boundary. *Almost* expendable — containing one axis, replaceable with thought but not trivially — is correct.

## Fact-Check Your Own Evaluation

After completing all steps, **invoke `/fact-check` on your own output**. It catches findings talked away, functional boundaries rationalized without a named axis, untraced change scenarios, low blast radius used as an excuse to ignore a finding, and domain decomposition in volatility clothing.

**Phrase shapes that mean you stopped one step early**:

- *"could also be seen as encapsulating volatility"* — name the axis or it is functional.
- *"the interface would only need minor changes"* — minor changes still leak; the receptacle changes not at all.
- *"only used in one place, but that's fine"* — investigate; and *"fails Lowy's reuse test"* from import count alone is a symptom, not a diagnosis. Cite the axis, not the count.
- *"follows the framework's conventions"* — convention is not volatility analysis.
- *"could theoretically change independently"* — without a concrete scenario, there is no axis.
- *"out of scope" / "pre-existing"* — process judgment; there is no defer, fix it in this PR.
- *"encapsulates [domain entity]"* — entities are not axes; name what about the entity changes.
- *"variable, so we should encapsulate it"* — variable is not volatile; state the likelihood × effect risk.
- *"a new kind of [picker/dialog/error] for a new domain"* — run the prior-encapsulation check; a parallel receptacle duplicates encapsulation.
- *"each export passes §5 in isolation"* — §6.5 fires per package; read the exports list as a consumer and ask "what library is this?"

Revise before presenting if fact-check finds issues.

## Output Format

1. **Boundaries examined** — List each module boundary or decomposition decision reviewed.
2. **Volatility map** — For each boundary, state what volatility it encapsulates (or fails to), classified as sequence or activity where applicable.
3. **Findings** — Functionality-tracking boundaries with blast-radius analysis, symmetry violations, and layering inversions.
4. **Simplifications** — Concrete restructuring per finding.
5. **Fact-check result** — Result of `/fact-check`, including the phrase-shape check.
6. **Actions** — One entry per finding, including pre-existing or orthogonal findings. Each entry starts with a **bolded label (≤8 words)** and has exactly one disposition: **Fix in this PR** (the only forward action; the PR scope expands to absorb it) or **No-op** (rare: the diff already deletes it, or another entry subsumes it verbatim). **There is no Defer.**

Example: `**useViewport encapsulates ghost concern** — Fix in this PR: delete the hook, let FitAddon measure per-tile.`

No findings → **No actions.** Findings without actions are incomplete.

## Relationship to /hickey

These are complementary lenses. Hickey asks "are independent concerns interleaved?" Lowy asks "do boundaries encapsulate axes of change?" Run both on architectural decisions. When they disagree (Lowy: merge shared volatility; Hickey: a mode flag would complect), **unify the volatile axis without complecting the strategies** — use a shared module that encapsulates the volatile part while strategies stay private. If unification needs a mode flag, conditional branch, or type-switch, that is complecting; find the layer where unification is mechanical.