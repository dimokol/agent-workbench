# integration-branch-qa

Test several approved PRs at once on one local integration branch and one set of dev servers, while agents keep working in worktrees. You get a queue, a clickable checklist, a merge gate (`check-pr`) and a hook that stops agents from pushing that branch, switching the main checkout off it while someone is testing, or force-pushing a PR under test.

## Install
```
claude plugin marketplace add dimokol/agent-workbench
claude plugin install integration-branch-qa@dimokol
```

Without the plugin system: copy `skills/integration-branch-qa/` into your skills folder, run its `scripts/qa-branch.sh` from your project, and add `hooks/qa-branch-guard.sh` as a PreToolUse hook on `Bash` in settings.json.

Start with `qa-branch.sh init`, then `add <pr>`, `rebuild`, and `checklist` for the clickable page. The daily flow, and how to carry a fix made on the integration branch back to its PR, are in `skills/integration-branch-qa/SKILL.md`.

## Config
| Setting | `init` flag | Default |
| --- | --- | --- |
| base_branch | `--base` | main |
| integration_branch | `--branch` | qa-integration |
| remote | `--remote` | origin |
| qa_dir | `--dir` | .qa |
| checklist_port | `--port` | 4777 |

`init` saves these in `.qa/config`. An env var `INTEGRATION_BRANCH_QA_<SETTING>` overrides one, and `GH_REPO=owner/repo` overrides the repo read from the remote URL. While someone holds the lock (`qa-branch.sh owner <name>`), `rebuild` refuses and the hook blocks switch, reset and stash in the main checkout. A command starting with `QA_BRANCH_ALLOW=1` gets past those and the force-push block once.

## Turn it off
`claude plugin disable integration-branch-qa@dimokol`

## Requirements
Tested on macOS. The Linux code paths exist but haven't been run on Linux yet. Needs bash 3.2+ and git. gh and jq for `add` and `check-pr`; node 18+ for the checklist page. Without jq the hook lets everything through and says so once. PRs from forks can't be queued. Tests: `bash tests/run.sh`.
