# Running several agents at once

One agent means you wait while it works, then it waits while you read. Two to five agents means
something is always moving. It also means agents step on each other's files and nobody knows what
the agent in the next terminal decided. This page is the
setup that keeps that manageable. Where a part of this repo helps, the step links to it.

## 1. One worktree per agent

Give every agent its own checkout of the repo so they never edit the same files on disk:

```bash
git worktree add ../myapp--search -b feature/search
cd ../myapp--search && claude
```

Each worktree is a full working copy on its own branch, sharing one `.git`. Name them so they sort
next to the main folder. When the PR merges, remove the worktree.
[`worktree-hygiene`](../plugins/worktree-hygiene) lists the ones that are safe to remove, and
[`verify-before-building`](../plugins/verify-before-building) checks the trunk before you start, in
case another agent already shipped the thing.

## 2. Subagents for fan-out inside one session

A subagent is a helper the current session starts with its own fresh context. Use one when a job
means reading a lot to get a short answer: a wide code search, comparing three libraries, reviewing
a diff from several angles. Ask for it plainly: "use subagents to check each of these five modules
for X and give me a one-line verdict per module". The helpers do the reading in parallel, and only
their summaries come back, so the file contents they read never enter your main session's context.

## 3. Let agents talk to each other

When the agent building the API and the agent building the screen need to agree on a field name,
don't copy messages between terminals. With [`agent-chat`](../plugins/agent-chat) installed, tell
both: "join the room `search-api` and agree on the response shape, then continue". They post, wait
for each other, and leave a transcript you can read later. Agents in the same repo or its worktrees
meet on their own. When the API and the screen live in different repos, start both agents with the
same project name, for example `AGENT_CHAT_PROJECT=search claude`.

## 4. Guardrails before speed

More agents means more chances for one of them to do something you didn't ask for.

- [`git-guardrails`](../plugins/git-guardrails): no PR merges, no pushes to main, no remote branch
  deletes and no `reset --hard` without your say. Turn on strict mode so every commit and push needs
  a go from you.
- [`machine-pressure`](../plugins/machine-pressure): one e2e or Docker run at a time, no heavy
  builds while the machine is in the red, and a statusline script you add by hand that shows CPU,
  RAM, swap and disk at a glance.
- [`context-nudge`](../plugins/context-nudge): a reminder to compact or start fresh when a session's
  context passes 250k, 400k and 600k tokens (you can change these), or it sits idle with a large
  context.

## 5. Review and test without becoming the bottleneck

- [`pr-review-loop`](../plugins/pr-review-loop) takes each PR through review: asks the reviewer
  once, applies or answers each finding, reruns the checks, and stops when it's ready for you to
  merge.
- [`integration-branch-qa`](../plugins/integration-branch-qa) lets you test several approved PRs in
  one sitting on one local branch, with a checklist per PR, instead of switching branches for each
  one.

## A typical day

1. Morning: [`worktree-hygiene`](../plugins/worktree-hygiene) lists yesterday's merged worktrees,
   and you approve each removal.
2. Plan three tasks, one worktree and one agent each.
3. While they build, a fourth session takes PRs through review with
   [`pr-review-loop`](../plugins/pr-review-loop).
4. Late afternoon: queue the approved PRs in
   [`integration-branch-qa`](../plugins/integration-branch-qa), test them together, merge the ones
   that pass.

Start with two agents. Add a third when you notice yourself waiting.
