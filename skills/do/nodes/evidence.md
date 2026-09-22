---
name: evidence
description: Attach empirical evidence to the PR (opt-in).
---

# Evidence

## Requires

- `--no-vcs` flag
- CI passed

## Ensures

- Evidence posted as PR comment (if configured)

## Strategies

Nickel always routes a non-minimal run to this node; the node itself is the sole place that detects
whether the project has configured PR evidence.

- **If `--no-vcs`**: skip with status `skipped` and reason `"--no-vcs"` — there is no PR to attach evidence to.
- **If `!supportsPrComment`**: skip with reason `"forge does not support PR comments"`.
- **Otherwise**: read `.agency/do.md` and look for a `## PR evidence` section. If missing or empty, skip
  with reason `"no PR evidence section in .agency/do.md"` — the default for projects that haven't opted in.

**The trigger is visual *or* behavioral.** Visual: screenshots, recordings (video when motion is the
point). **Behavioral** — proof that state survives an interaction or a restart — is easy to
under-fire on: persistence, restore, session, autosave, debounce/coalesce, and reconnect fixes often
have **no visual diff** yet are exactly where a survives-restart capture proves recoverability. Bug
fixes default to "demonstrate the fixed behavior" even when nothing looks different; gate on "is there
a behavior worth proving", not on a pixel changing.

**Read the trigger broadly.** The project's section supplies the capture *mechanism*; the criterion
for *when to fire* is the visual-or-behavioral framing above. If the section's wording leans visual but
the diff is a behavioral fix, capture the behavior anyway. Skip only when there is genuinely no
behavior worth proving (pure refactor, docs change, internal cleanup with no observable
before→after).

**If the section is present**: it is free-form — inline prose, pointer to another file, script
reference, or any combination. Read it, then **spawn a sub-agent** via the `task` tool (default
`agent: "task"`) so the capture work doesn't pollute `/do`'s main context. The sub-agent prompt
includes:

- The literal section content from `.agency/do.md`.
- Standard PR context: PR URL, branch name, base branch, current commit SHA, and changed files via
  the `vcs_read` tool with `{ args: ["diff-names"] }`.
- An explicit instruction to **return a single block of markdown** suitable for posting under a
  `## Evidence` heading — not post the comment itself.

After the sub-agent returns, post its output as one PR comment by calling the `forge` tool with
`{ op: "pr-comment", args: [], body: "## Evidence\n\n<markdown returned by the sub-agent>" }`. Embed
image/asset URLs inline — the comment operation cannot attach files; the section's mechanism is
responsible for hosting binary artifacts so they end up referenceable.

**Verify**: the step was skipped per the rules above, or a `## Evidence` PR comment exists.