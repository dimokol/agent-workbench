---
name: integration-branch-qa
description: Test several approved PRs at once on one local integration branch (base plus every PR under test), with a queue, a clickable checklist and a merge gate. Use when asked to "test these PRs together", "queue this PR for QA", "rebuild the QA branch" or "is this PR ready to merge".
---

# Integration branch QA

A person tests several approved PRs at once on one set of local dev servers, without switching branches, while agents keep working in worktrees. The main checkout (the first entry of `git worktree list`, where the dev servers run) sits on a local integration branch: the base branch plus every queued PR, each merged in with `--no-ff`. That branch is never pushed and never merged. Each PR still merges from its own branch.

Files in the main checkout (git ignores them):

- `.qa/config`: the settings, written by `init`.
- `.qa/queue.md`: its `qa-queue` block lists the PRs in the branch, in merge order. Notes and a log follow.
- `.qa/checklist.md`: one `## #<pr>: <what>` section per PR, with 1 to 3 `- [ ]` items.
- `.qa/lock` (optional): names who is testing. While it exists, agents don't rebuild, switch, reset or stash the main checkout.

## When to use it

- Approved PRs (review done, CI green) need a hands-on test before they merge, and more than one is waiting.
- Someone asks whether a tested PR may merge now.

PRs with nothing to click (CI, docs, internals) skip this and merge on the person's go.

## Run the script

Run `scripts/qa-branch.sh <command>` from this skill's folder with bash, while your working directory is the project (its main checkout or any of its worktrees). Claude Code shows this skill's base directory when it loads the skill; elsewhere it's the folder this SKILL.md sits in. Below, `qa <command>` means that call.

It needs git. `add` and `check-pr` also need gh and jq, and `checklist` needs node.

| Command | What it does |
| --- | --- |
| `init [--base B] [--branch I] [--remote R] [--dir D] [--port P]` | Saves the settings in `.qa/config` and creates the queue and checklist. Run it again with a flag to change one setting. |
| `add <pr>` | Queues an open PR (gh finds its branch), fetches it, starts its checklist section with a placeholder item. |
| `remove <pr> [--force]` | Drops the PR from the queue and its section from the checklist. Refuses while boxes are unticked, unless `--force`. |
| `rebuild [--allow-stranded]` | Builds the branch from `<remote>/<base>` plus the queue in a throwaway worktree, then moves the main checkout to it in one step. On a conflict it stops, changes nothing and names the PR. The old head stays on `<branch>-prev`. |
| `status` | The lock, how far behind the base the branch is, each queued PR (IN, MOVED, NOT IN, GONE), PRs merged in but no longer queued, and stranded fixes. |
| `check-pr <pr>` | The merge gate. Exit 0 means ready. |
| `checklist` | Serves the checklist as a page on localhost (the next free port if the set one is taken). Ticks write back to the file. |
| `owner [<who>]`, `release` | Shows the lock, sets it to a label (free text, like the tester's name), or drops it. |

## Set up

1. `qa init`, with flags for anything that differs from the defaults (see Config). If the project's CLAUDE.md has an `## integration-branch-qa config` block, pass its values as these flags.
2. Tell the person to run their dev servers from the main checkout.
3. When they start testing, `qa owner <their name>`. They `release` when done.

## Daily flow

1. Queue. For each approved PR, `qa add <pr>`. Replace the placeholder in its checklist section with 1 to 3 items: what to click and what should happen, in words the person testing understands. `check-pr` fails while the placeholder is there. When one PR needs another merged first, say so under Notes in `queue.md`.
2. Rebuild. `qa rebuild`. While the lock is held, rebuild only when the person asks, as `QA_BRANCH_ALLOW=1 qa rebuild`. On a conflict, resolve it on the PR's branch: in a worktree, merge `<remote>/<base>` or the clashing PR's branch into it, push, then rebuild again. Never resolve a conflict only on the integration branch.
3. Test. Start `qa checklist` as a background command and give the person the URL it prints. Tell them which dev servers to restart.
4. Fix. A bug found while testing gets fixed on the PR's own branch, in a worktree, and pushed. Then rebuild and ask for a retest of the affected items.
5. Gate. `qa check-pr <pr>` before any merge. It passes when the integration branch holds the PR's current head (or the same changes as its newer commits), GitHub sees no conflict, no stranded fix touches the PR's files, and its checklist section has real items, all ticked. Quote any FAIL lines to the person.
6. Merge. Only on the person's explicit go, merge the PR from its own branch, the way the project normally merges. Never merge the integration branch.
7. Clean up. `qa remove <pr>`, then rebuild so the branch picks up the new base.

Run `qa status` before each testing round and whenever someone pushes to a queued PR. MOVED means the PR got commits after its last merge-in: rebuild, then retest what changed.

## Stranded fixes

A commit made directly on the integration branch exists nowhere else, and the next rebuild drops it. `status` lists these as STRANDED, and `rebuild` refuses while any exist. Carry each one to the PR it belongs to. If an agent's worktree already has that PR branch checked out, cherry-pick there and push. Otherwise use a detached worktree, which works even when a stale local branch of that name exists:

```sh
git worktree add --detach ../carry-<pr> <remote>/<pr-branch>
cd ../carry-<pr> && git cherry-pick <sha> && git push <remote> HEAD:<pr-branch>
```

Then remove that worktree and rebuild. `status` recognises a carried commit by its diff (patch-id) or by its content already being on the branch, so the subject doesn't matter. `rebuild --allow-stranded` drops them on purpose; they stay reachable from `<branch>-prev` until the next rebuild.

## Rules

- Never push the integration branch (or its `-prev` copy), open a PR from it, or merge it anywhere. The guard hook blocks pushes of both.
- Fixes go to PR branches. The integration branch only receives the merges `rebuild` makes.
- While the lock is held, agents don't rebuild, switch the main checkout's branch, `reset --hard` or `stash` there, because the dev servers run from it. Work in worktrees. The hook blocks the switch, reset and stash; `rebuild` refuses on its own.
- `QA_BRANCH_ALLOW=1` at the start of a command gets past those blocks and the force-push block. Use it only when the person testing asks for that exact command.
- Don't force-push a queued PR's branch (the hook blocks it). Merge the base in instead of rebasing.
- A PR leaves the queue and the checklist only when every box is ticked, or when the person drops it (`qa remove <pr> --force`).
- Merging needs the person's explicit go, even when `check-pr` passes. A failing `check-pr` blocks the merge until it's fixed or the person overrides it.

## Config

| Setting | `init` flag | Default |
| --- | --- | --- |
| base_branch: the branch PRs target | `--base` | `main` |
| integration_branch: the local branch the main checkout tests on (never the base, main or master, since rebuild rewrites it) | `--branch` | `qa-integration` |
| remote: holds the base and PR branches | `--remote` | `origin` |
| qa_dir: folder for the queue, checklist and lock | `--dir` | `.qa` |
| checklist_port: port of the checklist page | `--port` | `4777` |

The script and the guard hook read each setting from the env var `INTEGRATION_BRANCH_QA_<SETTING>` (uppercased), then `.qa/config`, then the default. `GH_REPO=owner/repo` overrides the GitHub repo taken from the remote's URL.
