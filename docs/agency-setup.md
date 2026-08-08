# Agency Setup

Agency is an [OMP (Oh My Pi)](https://github.com/can1357/oh-my-pi) marketplace plugin. Setup is two commands.

## Install

```bash
omp plugin marketplace add srid/agency
omp plugin install agency@agency
```

This installs:
- **Skills** (`talk`, `do`, `hickey`, `lowy`, `code-police`, `fact-check`, `elegance`, `ralph`, `forge-pr`) — discovered from the plugin's `skills/` directory
- **Agents** (`hickey`, `lowy`) — discovered from the plugin's `agents/` directory, available as `task` tool agent types
- **Extension** (`stop-guard`) — a `session_stop` handler that prevents the agent from stopping mid-`/do` workflow

For local development:

```bash
omp plugin link ./path/to/agency
```

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