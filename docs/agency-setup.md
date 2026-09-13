# Agency Setup

Agency is an [OMP (Oh My Pi)](https://github.com/can1357/oh-my-pi) marketplace plugin. Setup is two commands.

## Install

Add the published Pages marketplace catalog (a direct `.json` URL that OMP
fetches as a catalog) and install from it. The catalog pins the plugin source
to an immutable `dist-<source-sha>` tag and exact distribution commit, so
installs never clone `main`:

```bash
omp plugin marketplace add https://develop7.github.io/omp-agency/marketplace.json
omp plugin install agency@omp-agency
```

This installs:
- **Skills** (`talk`, `do`, `hickey`, `lowy`, `code-police`, `fact-check`, `elegance`, `ralph`, `forge-pr`) — discovered from the plugin's `skills/` directory
- **Agents** (`hickey`, `lowy`) — discovered from the plugin's `agents/` directory, available as `task` tool agent types
- **Extension** (`agency-tools`) — registers the five `/do` operation tools (`vcs_read`, `vcs_write`, `forge`, `workflow`, `agency_driver`) over the PureScript core

For local development:

```bash
omp plugin link ./path/to/agency
```

> **Build first.** A source checkout ships no generated runtime artifacts.
> Run `just build nickel-build` inside the checkout before linking — without
> the built `pure/dist/agency-api.js` and `nickel-vm/dist/` glue the extension
> cannot load.

For PureScript and Nickel WASM development, the repository root provides recipes that self-route
through the pinned Nix toolchain: run `just test` or `just ci` directly from a bare host, and inside
`nix develop` they run without re-entering. Bundle-level recipes build the generated artifacts
first, so a clean checkout works out of the box.
The system `nickel` package is retained only as an
editor/debugging nicety; workflow runtime evaluation uses the `nickel-vm`
WebAssembly build produced by `just nickel-build`.

## Configure model tiers

Agency's sub-agents use the `@task` model role. Set it in your OMP config:

```yaml
# ~/.omp/agent/config.yml
modelRoles:
  task: anthropic/claude-sonnet-4-5
```

Service tiers for sub-agents are controlled by `tier.subagent` (default: `inherit`):

```yaml
tier:
  subagent: flex
```

## Configure project settings

Create `.agency/do.md` at the repo root to configure `/do` for your project:

```markdown
# /do config

## Check command
just check

## Format command
just fmt

## Test command
just test

## CI command
just ci

## Documentation
Keep README.md in sync with user-facing changes.
```

See [Project config](../README.md#project-config) in the README for the full list of `.agency/` files.