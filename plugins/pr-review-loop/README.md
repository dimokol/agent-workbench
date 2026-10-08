# pr-review-loop

Run `/pr-review-loop:pr-review-loop 12 14` and it asks the reviewer once, fixes or answers each finding, reruns your checks and stops when every PR is approved and mergeable. It asks for your go before it pushes, merges only with `--merge`, and `--double-review` adds its own review. Asking in plain words ("get these PRs ready") also triggers it.

## Install
```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install pr-review-loop@dimokol
```

Without the plugin system: copy `skills/pr-review-loop/` into `.claude/skills/` (Codex: `~/.codex/skills/`); the command is then `/pr-review-loop 12 14`. Set options as `key: value` lines in a `## pr-review-loop config` block in your CLAUDE.md. The skill reads the plugin setting first, then that block, then the default.

## Config
| Option | Default | What it does |
| --- | --- | --- |
| reviewer | empty, asks you | GitHub login whose approval counts |
| ask_via | `github-review` | `github-review` requests a review, `comment` posts one mention |
| gate_command | `gh pr checks <n> --watch` | What must pass before READY |
| e2e_command | empty | Extra suite, run when the diff changes behavior |
| max_rounds | 3 | Review rounds per PR before it hands back |
| poll_seconds | 60 | How often the watcher polls GitHub |
| bump_after_minutes | 10 | Silence before one reminder |
| worktree_pattern | `<repo>--pr-<n>` | Worktree folder, next to your checkout |
| merge_method | `squash` | Used only with `--merge` |

## Turn it off
`claude plugin disable pr-review-loop@dimokol`

## Requirements
GitHub, `gh` logged in as someone other than the reviewer, git with worktrees, bash. Tested on macOS. The Linux code paths exist but haven't been run on Linux yet. Script tests: `bash tests/run.sh` (needs jq).
