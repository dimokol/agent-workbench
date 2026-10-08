# verify-before-building

Before a branch is created, the agent fetches and checks whether the trunk already has the feature, so work a parallel agent or teammate merged doesn't get rebuilt.

## Install
```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install verify-before-building@dimokol
```

Without the plugin system: copy `skills/verify-before-building/` into `~/.claude/skills/` (or your project's `.claude/skills/`).

It triggers on phrases like "start a branch" or "begin work on X".

## Config
No settings. The agent works out the trunk and base branch names from your repo.

## Turn it off
`claude plugin disable verify-before-building@dimokol`

## Requirements
`git` with an `origin` remote. Any OS.
