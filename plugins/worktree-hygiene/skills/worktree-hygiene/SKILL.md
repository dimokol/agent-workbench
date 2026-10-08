---
name: worktree-hygiene
description: Read-only audit of free disk, worktrees whose PR is merged, idle dependency folders and orphaned dev servers. Use when starting a session, when asked for a "health check", "disk check" or "audit worktrees", or when the laptop is low on space.
---

# worktree-hygiene

Audit first, delete never. Run the checks, print one table, propose commands, and wait for the user to approve each removal.

## Config

A value that still reads as a literal `${...}` or is blank means unset; use the default.

- `worktree_filter`: plugin option `${user_config.worktree_filter}`, else `worktree_filter:` in the `## worktree-hygiene config` block of the project's CLAUDE.md, else empty. Only audit worktrees whose path contains this text; empty means every `git worktree list` entry.
- `dev_server_pattern`: plugin option `${user_config.dev_server_pattern}`, else `dev_server_pattern:` in the same block, else `next dev|vite|webpack|node --watch|nodemon`. Extended regex for orphaned dev servers.

## Checks

Run independent checks in parallel. Skip any check whose tool is missing and say so.

1. Free disk. `df -h /` (on macOS also `df -h /System/Volumes/Data`, the volume that fills up). Under 10 GB is RED, under 20 GB is AMBER.
2. Worktrees. For each repo the user works in, run `git -C <repo> worktree list --porcelain`. Keep only paths containing the worktree filter, if one is set. For every worktree outside the main checkout:
   - Dirty or has unpushed commits (`git -C <path> status --porcelain`, `git -C <path> log @{u}.. --oneline`): KEEP, report it. A branch with no upstream counts as unpushed.
   - Branch's PR is merged and the worktree is clean: REMOVE candidate. Find merged branches with `gh pr list --state merged --limit 50 --json number,headRefName`. Without `gh`, use `git branch --merged origin/<trunk>`.
   - Branch has no PR: report as possibly forgotten, do not propose removal.
3. Idle dependency folders. `du -sh` on `node_modules` in project folders next to the active repo that you did not touch this session. Report folders over 300 MB.
4. Build caches. `du -sh` on `.next`, `.turbo`, `dist` and test-report folders in the active repo. Over 500 MB, propose removal (they rebuild).
5. Orphaned dev servers. List processes whose parent is PID 1 and whose command matches the dev server pattern:
   `ps -eo pid,ppid,etime,%cpu,command | awk '$2==1' | grep -E "<pattern>" | grep -v grep`
   Do not touch processes with a live shell parent.
6. Docker, only if `command -v docker` succeeds. Run `docker system df` and `docker buildx du | tail -3`. Buildx cache over 5 GB is AMBER, over 10 GB RED. If the daemon doesn't answer within a few seconds, report "Docker daemon not responding" and move on.

## Retention rule

- Open PR or uncommitted work: keep the worktree and its dependencies.
- PR merged and worktree clean: remove it.
- Never remove a worktree for the branch you are standing in.

## Output

```
Disk:       <free>/<total> free        OK | AMBER | RED
Docker:     <total> total, buildx <size>   (omit if not installed)

Worktrees to remove (PR merged, clean):
  <branch>  PR #<n>  ->  git worktree remove <path>
Worktrees to keep (uncommitted or unpushed work):
  <branch>  <what is pending>
Orphan dev servers: <n> (oldest <etime>)  ->  kill <pids>
Idle caches:
  <path> (<size>)  ->  rm -rf <path>

Suggested order: <biggest recovery first>
Estimated recovery: ~<size>
```

Every proposed command is for the user to approve. Do not run `git worktree remove`, `rm`, `kill` or `docker prune` until they say yes for that item. Use `git worktree remove` without `--force` so git refuses on dirty trees.

## Related

- Whether a branch duplicates work already on trunk: use the `verify-before-building` plugin.
- A fuller cleanup playbook for worktrees: pstack's worktree-cleanup at github.com/cursor/plugins.
