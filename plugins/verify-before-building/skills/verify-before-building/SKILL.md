---
name: verify-before-building
description: Check that the trunk doesn't already have a feature before you branch for it. Use when starting new work, like "start a branch", "new feature branch", "begin work on X" or "create a worktree", and before the first git checkout -b or git worktree add of a task.
---

# verify-before-building

Parallel agents and teammates merge to the trunk while you plan. Check what landed before you build.

Skip it for a one-line edit on a branch you're already on, or when continuing an existing branch.

## Steps

1. List the repos the work touches and the files, symbols or feature names you expect to add or change.
2. Fetch the trunk and your base branch in each repo. A fetch moves only `origin/*`, never your local branches, so compare against `origin/<base>` from here on.
   ```bash
   git -C <repo> fetch origin <trunk> <base> --quiet
   git -C <repo> rev-list --count origin/<base>..origin/<trunk>
   ```
   `<base>` is the branch you cut from. If it is the trunk itself, the count is 0 and step 3 still applies. If `<base>` has no remote branch (stacked work), the fetch errors on it: fetch the trunk alone, compare against local `<base>`, and say so.
3. Search the trunk for the feature, whatever the count says:
   ```bash
   git -C <repo> grep -n "<symbol or feature name>" origin/<trunk> -- <likely paths>
   git -C <repo> log origin/<trunk> --oneline -20 -- <likely paths>
   ```
   Also read the repo's changelog or docs for mentions of the feature.
4. Decide:
   - Already on the trunk: don't rebuild it. Build on the trunk's version and add only what is missing.
   - Partly there: keep the missing part, align the rest to the trunk's version.
   - Not there: go ahead.
   - Base is far behind the trunk (the count from step 2 is large): tell the user and suggest merging the trunk into the base first.
5. Create the branch from `origin/<base>`, or from `origin/<trunk>` if step 4 says so. If `<base>` has no remote branch, branch from local `<base>` instead:
   ```bash
   git -C <repo> checkout --no-track -b <branch> origin/<base>
   git -C <repo> worktree add --no-track <path> -b <branch> origin/<base>
   ```
   Use the same branch name in every repo the work spans.
6. Say what you found ("`<area>` is not on the trunk" or "found on the trunk, building on it") before writing code. If you use a task board, mark the task in progress now (planning counts as starting).
