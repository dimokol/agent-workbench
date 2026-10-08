---
name: storage-reclaim
description: Free disk space on macOS without deleting anything in use or the only copy of something. Use when "free up space", "clean up my disk", "disk is full", "what's eating my disk", "reclaim space", or a build or install fails for lack of space.
---

# storage-reclaim

Needs zsh and is tested on macOS only. On Linux the scan is untested and skips the macOS-only sections.

A cleanup goes wrong in two ways. It deletes something a running process or another session is using, such as a `node_modules` under a live test run. Or it deletes the only copy of something, such as an archive that looks like a duplicate of an extracted folder but was never extracted. Checking before deleting takes seconds. Work through the phases in order.

## Config

A value that still reads as a literal `${...}` or is blank means unset; use the default.

- `lock_dir`: plugin option `${user_config.lock_dir}`, else `lock_dir:` in the `## storage-reclaim config` block of the project's CLAUDE.md, else empty (skip the check). A folder name your sessions use to mark active work.
- `worktree_suffix`: plugin option `${user_config.worktree_suffix}`, else `worktree_suffix:` in the same block, else empty (skip the check). The ending of folders that hold other sessions' worktrees.

## Phase 1: Measure

Run `scripts/scan.sh` from this skill's folder with zsh. It is read-only. If `lock_dir` or `worktree_suffix` is set, pass them as the environment variables `STORAGE_RECLAIM_LOCK_DIR` and `STORAGE_RECLAIM_WORKTREE_SUFFIX` on the same command line.

It prints free space, swap, the biggest home directories, known high-yield candidates with sizes, and what makes deletion unsafe right now. Read it before proposing anything. Look for the few items worth 5 GB or more, not a list of 50 MB items. The space is usually in superseded tool versions, SDK and simulator runtimes, VM images, dependency folders and browser caches.

- Free space on macOS is measured on the Data volume (`df -h /System/Volumes/Data`). `/` is a read-only snapshot and always looks fine.
- A large `/System/Volumes/VM` is swap. Closing apps returns it. Say so instead of hunting for files.

## Phase 2: Safety gate

Before proposing any delete, check what is using each candidate:

```bash
ps -eo pid,command | grep -iE "jest|vitest|next dev|node --watch|webpack|vite|tsc|npm|pnpm|yarn|gradle|xcodebuild" | grep -v grep
lsof +D <path> 2>/dev/null | head
```

`lsof +D` is slow on huge trees. Run it on the paths you are about to propose.

- A dependency folder or build cache with a live process attached is off limits until that process ends. This includes processes you did not start.
- Other sessions count as running processes. Anything under a lock entry, a worktree folder or a dev server the scan listed is untouchable.
- If a sweep could affect a shared project tree, name the paths in your report before acting so another session can object.

## Phase 3: Verify items that may hold content

Caches and old tool versions can be rebuilt. Anything that might hold content gets one check first.

| Looks like | Check before deleting |
| --- | --- |
| An archive next to a folder of the same name | Compare the archive listing (`unzip -l`) with the folder. Transfer links expire, so an unextracted archive may be the last copy. |
| A `.dmg` or `.pkg` | Is the app installed in `/Applications`? |
| Anything in Downloads, Documents or Desktop | This is the user's content. It goes in the ask-first tier at any size. |
| A VM image or container volume | Does it hold state (a database, a configured environment) or is it a rebuildable base image? |

When a check is ambiguous, keep the file and say why.

## Phase 4: Propose in tiers

Show a table of candidates with real sizes, largest first, split into two tiers. Delete nothing before the user answers, however obvious it looks.

Safe tier (rebuildable, no content, nothing in use):
- Superseded versions of auto-updating tools. Editors and CLIs often keep every version they downloaded. Keep the running one.
- Browser and updater caches.
- Build output: `.next`, `dist`, `build`, `target`, `.turbo`, DerivedData.
- Package manager caches: `~/.npm/_cacache`, `~/Library/Caches/pip`, Homebrew's cache.

Ask-first tier (recoverable but expensive, or user content):
- `node_modules` in projects not being worked on, when nothing is running.
- SDKs, simulator runtimes and devices, emulator images. Often the biggest win, and always a multi-GB re-download.
- VM bundles for local sandbox or agent features.
- Anything under Downloads, Documents or Desktop.

Never touch: git repositories and history, `.env` files and credentials, another session's worktree, anything a lock claims, the only copy of anything.

## Phase 5: Execute and verify

Delete only the items the user approved. Print each path with the size it freed.

- `rm -rf` can fail halfway on a subdirectory without the write bit and leave a half-deleted folder. Re-check anything reported as failed, run `chmod -R u+w` on it, finish the delete or report it as still present.
- Measure free space before and after with `df -h /System/Volumes/Data`, not by summing what you deleted. Report the real difference.

Close with the consequences:
- Which projects need a dependency install before they run.
- Which tools re-download on first use, and roughly how much.
- What you kept on purpose, and why.
- If swap inflated the numbers, that closing apps recovers that space too.

## Finding the big items

Ask "what is duplicated, and what regenerates?" instead of "what looks big?". VM bundles and simulator runtimes rarely show up in a glance at the projects folder, which is where people look first.
