# setup-audit

A weekly check of your Claude Code setup. It reads new changelog entries, diffs a community tool list against the last snapshot, runs your own drift checks, and appends a short log. It proposes and never changes config.

## Install

```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install setup-audit@dimokol
```

Without the plugin system: copy `skills/setup-audit/` into `~/.claude/skills/`.

## Config

| Option | Default | What it does |
| --- | --- | --- |
| `audit_dir` | `~/.setup-audit` | Folder for the log, snapshot and tripwires. The only place the skill writes. |

Without the plugin, put `audit_dir: <path>` in a `## setup-audit config` block in your CLAUDE.md.

## Turn it off

```
claude plugin disable setup-audit@dimokol
```

## Requirements

Network access to raw.githubusercontent.com. The example tripwires use `jq`, `grep`, `diff` and `wc`; edit them to fit your machine. Tested on macOS. The Linux code paths exist but haven't been run on Linux yet.
