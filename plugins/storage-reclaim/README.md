# storage-reclaim

Disk cleanup that measures where the space went, refuses to touch anything a running process or another session uses, checks that "obvious junk" really is junk, and frees space in tiers you approve one by one.

## Install
```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install storage-reclaim@dimokol
```

Without the plugin system: copy `skills/storage-reclaim/` into `~/.claude/skills/` and put the options below in a `## storage-reclaim config` block in CLAUDE.md. You can also run `scripts/scan.sh` yourself with `STORAGE_RECLAIM_LOCK_DIR` and `STORAGE_RECLAIM_WORKTREE_SUFFIX` set.

Ask for "free up space" or "what's eating my disk". `scripts/scan.sh` is read-only; every deletion needs your yes.

## Config
| Option | Default | What it does |
| --- | --- | --- |
| `lock_dir` | empty | Folder name that marks active work. Its contents are listed as in use. |
| `worktree_suffix` | empty | Folders ending in this are reported as other sessions' worktrees. |

The skill reads the plugin option, then the CLAUDE.md block, then the default. Only `scripts/scan.sh` reads the `STORAGE_RECLAIM_*` variables, which the skill sets for it.

## Turn it off
`claude plugin disable storage-reclaim@dimokol`

## Requirements
zsh. Tested on macOS only; on Linux the scan is untested. Test: `bash tests/run.sh`.
