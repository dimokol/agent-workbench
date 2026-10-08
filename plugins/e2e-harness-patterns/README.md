# e2e-harness-patterns

Patterns for a local end-to-end test harness that several agents can run in parallel: one stack per worktree, ports derived from the path, seeded data, Playwright, affected-only runs.

## Install

```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install e2e-harness-patterns@dimokol
```

Without the plugin system: copy `skills/e2e-harness-patterns/` into `~/.claude/skills/`.

## Config

| Option | Default | What it does |
| --- | --- | --- |
| `max_stacks` | `2` | How many stacks may run at once on the machine. |

Without the plugin, add `max_stacks: <n>` in a `## e2e-harness-patterns config` block in your CLAUDE.md.

## Turn it off

```
claude plugin disable e2e-harness-patterns@dimokol
```

## Requirements

A reference skill with no scripts. The examples assume Node, Playwright and git worktrees on macOS or Linux. Docker is only needed for the fallback mode.
