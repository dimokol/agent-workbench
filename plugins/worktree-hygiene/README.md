# worktree-hygiene

A read-only audit you run at session start: free disk, worktrees whose PR is merged, worktrees with unfinished work, idle dependency folders, orphaned dev servers and (if Docker is installed) the Docker cache size. It proposes removals and never deletes on its own.

## Install
```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install worktree-hygiene@dimokol
```

Without the plugin system: copy `skills/worktree-hygiene/` into `~/.claude/skills/` (or your project's `.claude/skills/`) and put the options below in a `## worktree-hygiene config` block in CLAUDE.md.

Then ask for a "health check" or "audit worktrees".

## Config
| Option | Default | What it does |
| --- | --- | --- |
| `worktree_filter` | empty | Only audit worktrees whose path contains this text. Empty means every `git worktree list` entry. |
| `dev_server_pattern` | `next dev\|vite\|webpack\|node --watch\|nodemon` | Regex used to find orphaned dev servers. |

The skill reads the plugin option, then the CLAUDE.md block, then the default. It does not read environment variables.

## Turn it off
`claude plugin disable worktree-hygiene@dimokol`

## Requirements
Tested on macOS. The Linux code paths exist but haven't been run on Linux yet. Needs `git`. Optional: `gh` (merged-PR lookup, falls back to `git branch --merged`) and `docker`.
