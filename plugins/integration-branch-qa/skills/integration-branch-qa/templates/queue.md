# QA queue

The integration branch is the base branch plus every PR in the block below, merged in this order with `--no-ff`. It lives only on this machine: it is never pushed and never merged. Each PR merges from its own branch once `check-pr` passes. The branch names are in `.qa/config`.

Change the block with `qa-branch.sh add <pr>` and `remove <pr>`, then run `rebuild`. One line per PR: `<number> <branch>`.

```qa-queue
```

## Notes

Merge order between queued PRs, clashes resolved on their branches, steps to run at deploy.

## Done

`remove` adds a line here for each PR that leaves the queue.

