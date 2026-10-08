# pr-task-link-guard

`gh pr create` is refused until the PR body links a task on your task board.

A `PreToolUse` hook on Bash. The link passes when it appears anywhere in the command (an inline `--body`, or a heredoc that writes the body file in the same command) or in the file passed to `--body-file` or read by `--body "$(cat body.md)"`, relative to the session's working directory (`$PWD` and `$HOME` in the path are fine). The deny message tells the agent to find or create the task, add the link and try again. It does nothing until you set `task_link_pattern`, and says so once per session.

## Install
    claude plugin marketplace add dimokol/agent-workbench
    claude plugin install pr-task-link-guard@dimokol

Without the plugin system: clone the repo and add `plugins/pr-task-link-guard/hooks/pr-task-link-guard.sh` as a `command` hook under `PreToolUse` with matcher `Bash` in `~/.claude/settings.json`. Set options through that file's `env` block.

## Config
Set options at install (`claude plugin install pr-task-link-guard@dimokol --config 'task_link_pattern=linear\.app/[^/]+/issue/'`), with `/plugin configure pr-task-link-guard@dimokol` in a session, or by piping a JSON object of strings to `claude plugin configure pr-task-link-guard@dimokol --values-stdin`, then restart Claude Code. The env vars only apply to a hand-wired setup.

| Option | Env var | Default | What it does |
| --- | --- | --- | --- |
| `task_link_pattern` | `PR_TASK_LINK_GUARD_TASK_LINK_PATTERN` | empty (off) | JavaScript regex, case-insensitive, that the task link must match. For example `linear\.app/[^/]+/issue/` or `github\.com/[^/]+/[^/]+/issues/\d+`. |
| `repo_scope` | `PR_TASK_LINK_GUARD_REPO_SCOPE` | empty (all repos) | Regex on the `owner/repo` slug, taken from `--repo`, `GH_REPO` or the repo's git remotes. Only matching repos are checked. |

For a PR that really has no task, the agent writes `PR_TASK_LINK_GUARD_ALLOW=1` directly before `gh pr create`, and the deny message says to do that only when you said so. `gh pr new` is checked the same way.

## Turn it off
    claude plugin disable pr-task-link-guard@dimokol

## Requirements
Node 18 or newer on `PATH` (without it, PRs pass and the hook says so once per session) and the `gh` CLI. Tests pass on macOS and Linux in CI, and day-to-day use so far is on macOS. Tests: `node --test tests/*.test.mjs` from this folder.
