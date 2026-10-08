# git-guardrails

Your agents can't merge PRs, push to protected branches, delete remote branches or run `reset --hard`, `clean -f`, `branch -D` or `stash drop` until you say so. Force pushes to branches that aren't protected pass unless strict is on.

A `PreToolUse` hook reads each Bash command the way a shell would (quotes, line continuations, `$(...)`, heredocs, `sh -c`) and denies the risky ones with a reason the agent can act on. Treat it as a speed bump against mistakes, and don't rely on it as a sandbox: a script or a git alias goes unseen. It reads a branch name from a variable only when `NAME=value` or `export NAME=value` set it earlier in the same command; one set through `declare`, `read`, `+=`, a `for` loop or a subshell goes unseen too. Turn on `strict` if you can: the agent then has to ask before anything leaves your machine.

## Install
    claude plugin marketplace add dimokol/agent-workbench
    claude plugin install git-guardrails@dimokol

Without the plugin system: clone the repo and add `plugins/git-guardrails/hooks/git-guardrails.sh` as a `command` hook under `PreToolUse` with matcher `Bash` in `~/.claude/settings.json`. Set options through that file's `env` block.

## Config
Set options at install (`claude plugin install git-guardrails@dimokol --config strict=true`), with `/plugin configure git-guardrails@dimokol` in a session, or with `echo '{"strict":"true"}' | claude plugin configure git-guardrails@dimokol --values-stdin`, then restart Claude Code. The env vars only apply to a hand-wired setup.

| Option | Env var | Default | What it does |
| --- | --- | --- | --- |
| `block_merges` | `GIT_GUARDRAILS_BLOCK_MERGES` | `true` | Denies `gh pr merge`, merges through `gh api` or `curl` to api.github.com (REST and GraphQL), and `git merge` while a protected branch is checked out (`--ff-only` passes). |
| `protected_branches` | `GIT_GUARDRAILS_PROTECTED_BRANCHES` | `main,master` | Denies pushes to these (`+main`, `HEAD:main`, `refs/heads/main`, `--all`), a bare `git push` while one is checked out, and writes through the GitHub API (a branch-ref update, a contents-API commit). `*` globs work. |
| `block_branch_delete` | `GIT_GUARDRAILS_BLOCK_BRANCH_DELETE` | `true` | Denies `push --delete`, `:branch` refspecs, a refspec source from a variable not written `${VAR:?}` or from `$(...)`, `--mirror`, `--prune` and `gh pr close --delete-branch`. |
| `block_destructive` | `GIT_GUARDRAILS_BLOCK_DESTRUCTIVE` | `true` | Denies `reset --hard`, `clean -f`, `branch -D`, `stash drop` and `stash clear`. |
| `strict` | `GIT_GUARDRAILS_STRICT` | `false` | Also denies every `git commit` and `git push`. |

To let one approved command through, the agent writes `GIT_GUARDRAILS_ALLOW=1` directly before it, for example `cd app && GIT_GUARDRAILS_ALLOW=1 git push origin main`. The deny message tells it to do that only when your latest message asked for that exact action.

## Turn it off
    claude plugin disable git-guardrails@dimokol

## See also
[mattpocock/skills](https://github.com/mattpocock/skills) has a git-guardrails skill with the same aim.

## Requirements
Node 18 or newer on `PATH` (without it, commands pass and the hook says so once per session) and `git`. Tested on macOS. The Linux code paths exist but haven't been run on Linux yet. Tests: `node --test tests/*.test.mjs` from this folder.
