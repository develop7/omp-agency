---
name: evidence
description: Attach empirical evidence to the PR (opt-in).
---

# Evidence

## Requires

- `--minimal` flag
- `--no-vcs` flag
- CI passed

## Ensures

- Evidence posted as PR comment (if configured)

## Strategies

**If `--minimal`**: Skip with status `skipped` and reason `"--minimal"`. Move to **done**.

**If `--no-vcs`**: Skip with status `skipped` and reason `"--no-vcs"`. There is no PR to attach evidence to.

**If `!supportsPrComment`**: Skip with status `skipped` and reason `"forge does not support PR comments"`. (Bitbucket comment wiring is tracked in #10.)

**Otherwise**: Read `.agency/do.md` and look for a `## PR evidence` section. If missing or empty, skip with status `skipped` and reason `"no PR evidence section in .agency/do.md"` — the default for projects that haven't opted in.

**The trigger is visual *or* behavioral.** The proof that matters is sometimes a pixel diff (visual) and sometimes "does
state survive the interaction or a restart?" (behavioral). A behavioral fix — persistence, restore, session, autosave,
debounce/coalesce, reconnect — routinely has **no visual diff** yet is exactly where a survives-restart capture proves
the fix didn't break recoverability. Bug fixes default to "demonstrate the fixed behavior" even when nothing _looks_
different; gate evidence on "is there a behavior worth proving," not on a pixel changing.

**Read the trigger broadly.** The project's `## PR evidence` section supplies the capture mechanism; the criterion for
_when to fire_ is the visual-or-behavioral framing above. If the section's wording leans visual ("when the change has
visible UI impact") but the diff is a behavioral fix, capture the behavior anyway — the absence of a visual diff is not
a reason to skip. Only skip when there's genuinely no behavior worth proving (a pure refactor, a docs change, an
internal cleanup with no observable before→after).

**If the section is present**:

The section is project-specific and free-form: inline prose, pointer to another file, script reference, or any combination. Read it, then **spawn a sub-agent** via the `task` tool (default `agent: "task"`) so the capture work doesn't pollute `/do`'s main context.

The sub-agent prompt should include:

- The literal section content from `.agency/do.md`.
- Standard PR context: PR URL, branch name, base branch, current commit SHA, and `bash scripts/vcs-op diff-names` (read-side seam — the toolkit's `repo_diff_range` is a real gap that vcs-op still covers).
- An explicit instruction that the sub-agent's job is to return a single block of markdown suitable for posting under a `## Evidence` heading.

After the sub-agent returns, post its output as one PR comment using `bash scripts/forge-op pr-comment --body-file -` under a `## Evidence` heading. Use the **stdin heredoc** pattern so backticks and `$` survive unescaped — `forge-op` pipes stdin straight to `gh --body-file -`:

```sh
bash scripts/forge-op pr-comment --body-file - <<'EOF'
## Evidence

<markdown returned by the sub-agent>
EOF
```

Embed image/asset URLs inline in the markdown — `forge-op pr-comment` itself cannot attach files; the workflow section is responsible for telling the sub-agent how to host any binary artifacts so they end up referenceable.

**Verify**: Either the step was skipped per the rules above, or a `## Evidence` PR comment exists.
