#!/usr/bin/env bash
# Tests for integration-branch-qa. Run: bash tests/run.sh
#
# Builds throwaway repos under mktemp -d (a bare remote, a "seed" clone that
# plays the PR authors, and "work", the main checkout), stubs gh with a fake
# that answers from JSON files, checks qa-branch.sh and the guard hook, then
# runs the node tests for the checklist server. Needs git, jq, node and curl.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
QA="$ROOT/skills/integration-branch-qa/scripts/qa-branch.sh"
GUARD="$ROOT/hooks/qa-branch-guard.sh"
BASH_BIN=$(command -v bash)
for t in git jq node curl; do command -v "$t" >/dev/null 2>&1 || { echo "tests need $t"; exit 2; }; done
T=$(mktemp -d "${TMPDIR:-/tmp}/qa-test.XXXXXX")
T=$(cd "$T" && pwd -P)
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"' EXIT

# Keep this machine's git config and settings out of the fixtures.
for v in $(env | sed -n 's/^\(INTEGRATION_BRANCH_QA_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset QA_BRANCH_ALLOW
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
git config --file "$GIT_CONFIG_GLOBAL" user.name "QA Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email qa@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false
export GH_REPO=acme/shop TMPDIR="$T/tmp"
mkdir -p "$TMPDIR" "$T/bin" "$T/gh"

# Fake gh: logs each call, answers `pr view N` from gh/pr-N.json, `pr list` from gh/pr-list.json.
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_GH/calls"
case "$1 $2" in
  "pr view") cat "$FAKE_GH/pr-$3.json" 2>/dev/null || { echo "no pull request $3" >&2; exit 1; } ;;
  "pr list") cat "$FAKE_GH/pr-list.json" 2>/dev/null || echo '[]' ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export FAKE_GH="$T/gh" PATH="$T/bin:$PATH"

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
nok() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      | /'; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) nok "$1" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) nok "$1" "$2" ;; *) ok "$1" ;; esac; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected [$3], got [$2]"; fi; }
matches() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok "$1"; else nok "$1" "$2"; fi; }

W="$T/work"
QUEUE="$W/.qa/queue.md"
CHECK="$W/.qa/checklist.md"
qa() { (cd "$W" && "$BASH_BIN" "$QA" "$@" 2>&1); }
put() { printf '%s\n' "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -q -m "$4"; }
pr_json() { # pr_json <n> <branch> [state] [mergeable]
  printf '{"headRefName":"%s","headRefOid":"%s","state":"%s","mergeable":"%s","baseRefName":"main","title":"PR %s","isCrossRepository":false}\n' \
    "$2" "$(git -C "$T/remote.git" rev-parse "refs/heads/$2")" "${3:-OPEN}" "${4:-MERGEABLE}" "$1" >"$FAKE_GH/pr-$1.json"
}
push_seed() { git -C "$T/seed" checkout -q "$1" && put "$T/seed" "$2" "$3" "$4" && git -C "$T/seed" push -q origin "$1"; }
items() { # replace the placeholder under "## #<n>" with a real item
  awk -v num="$1" '/^## / { on = ($0 ~ ("#" num "([^0-9]|$)")) } on && /Replace with/ { $0 = "- [ ] Open the page: the new text shows" } { print }' \
    "$CHECK" >"$T/ck" && mv "$T/ck" "$CHECK"
}
tick() {
  awk -v num="$1" '/^## / { on = ($0 ~ ("#" num "([^0-9]|$)")) } on { sub(/^- \[ \]/, "- [x]") } { print }' \
    "$CHECK" >"$T/ck" && mv "$T/ck" "$CHECK"
}

# Fixture: main; feat-a and feat-b (independent); feat-c (clashes with feat-a in
# a.txt); feat-d (adds d.txt).
git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$T/seed" 2>/dev/null
put "$T/seed" a.txt "a base" "base: a"
put "$T/seed" b.txt "b base" "base: b"
git -C "$T/seed" push -q origin main
for spec in "feat-a a.txt" "feat-b b.txt" "feat-c a.txt" "feat-d d.txt"; do
  set -- $spec
  git -C "$T/seed" checkout -q -b "$1" main
  put "$T/seed" "$2" "${2%.txt} from $1" "feat: $1"
  git -C "$T/seed" push -q origin "$1"
done
git clone -q "$T/remote.git" "$W"
for pr in "1 feat-a" "2 feat-b" "3 feat-c" "4 feat-d"; do pr_json $pr; done
pr_json 9 feat-b MERGED

echo "# init"
out=$(qa init)
has "init creates the queue" "$out" "created $QUEUE"
[ -f "$CHECK" ] && ok "init creates the checklist" || nok "init creates the checklist"
has "init saves the settings" "$(cat "$W/.qa/config")" "integration_branch=qa-integration"
is "git ignores the qa folder" "$(git -C "$W" status --porcelain)" ""
has "init keeps existing files" "$(qa init)" "kept $QUEUE"
out=$(qa init --port abc); code=$?
is "init refuses a bad port" "$code" 2

echo "# add"
has "add queues a PR" "$(qa add 1)" "queued #1 (feat-a)"
has "add passes the repo to gh" "$(cat "$FAKE_GH/calls")" "pr view 1 -R acme/shop"
has "add writes the queue line" "$(cat "$QUEUE")" "1 feat-a"
has "add starts a checklist section" "$(cat "$CHECK")" "## #1: PR 1"
has "adding twice is a no-op" "$(qa add 1)" "already queued"
is "still one queue line" "$(grep -c '^1 feat-a$' "$QUEUE")" 1
is "still one checklist section" "$(grep -c '^## #1:' "$CHECK")" 1
qa add '#2' >/dev/null
out=$(qa add 9); code=$?
is "add refuses a merged PR" "$code" 2
has "add says why" "$out" "#9 is MERGED"

echo "# rebuild"
git -C "$W" branch -q qa-integration origin/main
git -C "$W" branch -q -u origin/main qa-integration # as an older build would have left it
out=$(qa rebuild); code=$?
is "rebuild succeeds" "$code" 0
has "rebuild reports each merge" "$out" "merged #2 feat-b"
is "the main checkout is on the integration branch" "$(git -C "$W" branch --show-current)" qa-integration
is "both PRs are in" "$(cat "$W/a.txt" "$W/b.txt" | tr '\n' ' ')" "a from feat-a b from feat-b "
is "each PR is a --no-ff merge" "$(git -C "$W" rev-list --merges --count origin/main..qa-integration)" 2
is "merge subjects name the PR" "$(git -C "$W" log -1 --format=%s)" "qa: merge #2 (feat-b)"
git -C "$W" rev-parse --abbrev-ref 'qa-integration@{upstream}' >/dev/null 2>&1 &&
  nok "the integration branch has no upstream" || ok "the integration branch has no upstream"
is "the build worktree is gone" "$(git -C "$W" worktree list | wc -l | tr -d ' ')" 1
out=$(qa status)
matches "status: #1 is in" "$out" '#1 +feat-a +IN @'
has "status: nothing stranded" "$out" "stranded: none"

echo "# a PR moves"
push_seed feat-b b2.txt "more b" "feat: b part two"
pr_json 2 feat-b
matches "status shows the moved PR" "$(qa status)" '#2 +feat-b +MOVED .*1 commit\(s\) not on qa-integration'
out=$(qa check-pr 2); code=$?
is "check-pr fails a moved PR" "$code" 1
has "check-pr lists the untested commit" "$out" "feat: b part two"

echo "# a repeated subject is not proof of testing"
push_seed feat-b b.txt "b from feat-b, linted" "fix lint"
qa rebuild >/dev/null
items 2
tick 2
push_seed feat-b b2.txt "more b, new code" "fix lint"
pr_json 2 feat-b
matches "status counts the new commit as untested" "$(qa status)" '#2 +feat-b +MOVED .*1 commit\(s\) not on'
out=$(qa check-pr 2); code=$?
is "check-pr fails it" "$code" 1
has "check-pr lists it" "$out" "fix lint"

echo "# check-pr"
out=$(qa check-pr 1); code=$?
is "check-pr fails with unticked items" "$code" 1
tick 1
out=$(qa check-pr 1); code=$?
is "a ticked placeholder still fails" "$code" 1
has "check-pr says to write real items" "$out" "still holds the placeholder item"
items 1
out=$(qa check-pr 1); code=$?
has "check-pr counts unticked items" "$out" "1 of 1 checklist item(s) still unticked"
tick 1
out=$(qa check-pr 1); code=$?
is "check-pr passes when every check holds" "$code" 0
has "check-pr says ready" "$out" "RESULT: ready to merge from feat-a"
pr_json 1 feat-a OPEN CONFLICTING
out=$(qa check-pr 1); code=$?
is "check-pr fails on a GitHub conflict" "$code" 1
has "check-pr says where to resolve it" "$out" "merge origin/main into feat-a"
pr_json 1 feat-a
out=$(qa check-pr 3); code=$?
is "check-pr fails a PR that was never merged in" "$code" 1
has "check-pr notices the missing section" "$out" "no checklist heading names #3"

echo "# stranded fixes"
push_seed main base.txt "unrelated" "fix: a typo found in testing" # same subject, other change, on the base
put "$W" a.txt "a from feat-a, fixed" "fix: a typo found in testing"
fix=$(git -C "$W" rev-parse HEAD)
out=$(qa status)
has "status flags the stranded fix despite the same subject on the base" "$out" "STRANDED"
has "status names it" "$out" "fix: a typo found in testing"
out=$(qa check-pr 1); code=$?
is "check-pr fails while a stranded fix touches the PR's files" "$code" 1
has "check-pr says which" "$out" "stranded fixes on qa-integration touch this PR's files"
has "a stranded fix elsewhere doesn't block other PRs" "$(qa check-pr 2)" "no stranded fix on qa-integration touches its files"
out=$(qa rebuild); code=$?
is "rebuild refuses to drop a stranded fix" "$code" 2
has "rebuild names the fix" "$out" "fix: a typo found in testing"

echo "# carry the fix to its PR branch (the SKILL.md recipe)"
git -C "$W" worktree add -q --detach "$T/carry" origin/feat-a
git -C "$T/carry" cherry-pick "$fix" >/dev/null
git -C "$T/carry" push -q origin HEAD:feat-a
git -C "$W" worktree remove "$T/carry"
pr_json 1 feat-a
out=$(qa status)
has "a carried fix is no longer stranded" "$out" "stranded: none"
matches "its PR shows the change as already tested" "$out" '#1 +feat-a +MOVED .*already on qa-integration'
out=$(qa check-pr 1); code=$?
is "check-pr passes once the fix is carried" "$code" 0
has "check-pr explains why" "$out" "new changes are already on qa-integration"
git -C "$W" worktree add -q --detach "$T/empty" origin/feat-a
git -C "$T/empty" commit -q --allow-empty -m "ci: retrigger"
git -C "$T/empty" push -q origin HEAD:feat-a
git -C "$W" worktree remove "$T/empty"
pr_json 1 feat-a
out=$(qa check-pr 1); code=$?
is "an empty commit on a tested PR doesn't need a retest" "$code" 0
out=$(qa rebuild); code=$?
is "rebuild runs once nothing is stranded" "$code" 0
is "the rebuilt branch has the fix" "$(cat "$W/a.txt")" "a from feat-a, fixed"
has "the old head is kept" "$(git -C "$W" branch --list qa-integration-prev)" "qa-integration-prev"

echo "# conflicts"
before=$(git -C "$W" rev-parse qa-integration)
qa add 3 >/dev/null
out=$(qa rebuild); code=$?
is "rebuild stops on a conflict" "$code" 1
has "rebuild names the PR" "$out" "CONFLICT merging #3 (feat-c)"
has "rebuild lists the file" "$out" "  a.txt"
is "the integration branch is unchanged" "$(git -C "$W" rev-parse qa-integration)" "$before"
is "the main checkout's tree never moved" "$(cat "$W/a.txt")" "a from feat-a, fixed"
is "the build worktree is cleaned up" "$(git -C "$W" worktree list | wc -l | tr -d ' ')" 1
is "the working tree is clean" "$(git -C "$W" status --porcelain -uno)" ""

echo "# remove"
out=$(qa remove 3); code=$?
is "remove refuses a PR with unticked items" "$code" 2
has "remove says how to drop it" "$out" "pass --force"
out=$(qa remove 3 --force); code=$?
is "remove --force drops it" "$code" 0
lacks "the queue no longer lists it" "$(sed -n '/^```qa-queue/,/^```$/p' "$QUEUE")" "3 feat-c"
lacks "its checklist section is gone" "$(cat "$CHECK")" "## #3"
has "the queue logs it" "$(cat "$QUEUE")" "#3 (feat-c) left the queue"
has "other sections stay" "$(cat "$CHECK")" "## #1: PR 1"

echo "# an untracked file in the way"
qa add 4 >/dev/null
printf 'local scratch\n' >"$W/d.txt"
before=$(git -C "$W" rev-parse qa-integration)
out=$(qa rebuild); code=$?
is "rebuild fails when the main checkout can't move" "$code" 2
has "it shows git's reason" "$out" "d.txt"
lacks "it doesn't blame the PR branch" "$out" "Resolve it on the PR branch"
is "the integration branch is unchanged" "$(git -C "$W" rev-parse qa-integration)" "$before"
rm "$W/d.txt"
qa remove 4 --force >/dev/null

echo "# lock"
has "no lock at first" "$(qa owner)" "lock: free"
has "owner takes a free-text label" "$(qa owner Alice from QA)" "Alice from QA is testing"
out=$(qa rebuild); code=$?
is "rebuild refuses under the lock" "$code" 2
has "rebuild says how to go ahead" "$out" "QA_BRANCH_ALLOW=1"
out=$(cd "$W" && QA_BRANCH_ALLOW=1 "$BASH_BIN" "$QA" rebuild 2>&1); code=$?
is "rebuild runs under the lock when allowed" "$code" 0
has "status shows the lock" "$(qa status)" "lock: Alice from QA is testing"
has "release frees it" "$(qa release)" "was Alice from QA"
qa remove 2 --force >/dev/null
out=$(qa status)
has "status lists PRs merged in but no longer queued" "$out" "no longer queued"
matches "it names the branch" "$out" '^  feat-b$'

echo "# checklist page"
(cd "$W" && exec "$BASH_BIN" "$QA" checklist) >"$T/server.log" 2>&1 &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'http://localhost:' "$T/server.log" && break; sleep 0.5; done
url=$(sed -n 's#.*\(http://localhost:[0-9]*\).*#\1#p' "$T/server.log" | head -n 1)
has "checklist serves the file" "$(curl -s "$url/api")" '"## #1: PR 1"'
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

echo "# first build"
git clone -q "$T/remote.git" "$T/fresh"
(cd "$T/fresh" && "$BASH_BIN" "$QA" init && "$BASH_BIN" "$QA" add 1 && "$BASH_BIN" "$QA" add 3) >/dev/null 2>&1
out=$(cd "$T/fresh" && "$BASH_BIN" "$QA" rebuild 2>&1); code=$?
is "a first rebuild stops on a conflict" "$code" 1
is "the checkout stays on its branch" "$(git -C "$T/fresh" branch --show-current)" main
is "no integration branch is left" "$(git -C "$T/fresh" branch --list qa-integration)" ""

echo "# settings"
git clone -q "$T/remote.git" "$T/conf"
out=$(cd "$T/conf" && "$BASH_BIN" "$QA" init --branch qa-alt --dir testing --port 4800 2>&1)
has "init flags go to .qa/config" "$(cat "$T/conf/.qa/config")" "integration_branch=qa-alt"
[ -f "$T/conf/testing/queue.md" ] && ok "--dir moves the queue" || nok "--dir moves the queue" "$out"
is "git ignores both folders" "$(git -C "$T/conf" status --porcelain)" ""
st() { (cd "$T/conf" && "$BASH_BIN" "$QA" status 2>&1); }
has "the script reads .qa/config" "$(st)" "qa-alt: not built yet"
has "an env var wins over .qa/config" "$(INTEGRATION_BRANCH_QA_INTEGRATION_BRANCH=qa-env st)" "qa-env: not built yet"
has "init keeps earlier settings" "$(cd "$T/conf" && "$BASH_BIN" "$QA" init 2>&1)" "branch qa-alt"
for args in "--branch main" "--branch master" "--base dev --branch dev"; do
  out=$(cd "$T/conf" && "$BASH_BIN" "$QA" init $args 2>&1); code=$?
  is "init refuses $args" "$code" 2
done
has "a refused init leaves the config alone" "$(cat "$T/conf/.qa/config")" "integration_branch=qa-alt"
out=$(cd "$T/conf" && INTEGRATION_BRANCH_QA_INTEGRATION_BRANCH=main "$BASH_BIN" "$QA" rebuild 2>&1); code=$?
is "rebuild refuses to rewrite main" "$code" 2
has "it says why" "$out" "rebuild rewrites it"

echo "# GitHub repo from the remote URL"
git clone -q "$T/remote.git" "$T/slug"
(cd "$T/slug" && "$BASH_BIN" "$QA" init) >/dev/null
for pair in "git@github.com:acme/shop.git acme/shop" "https://github.com/acme/shop acme/shop" \
  "ssh://git@github.com:22/acme/shop.git acme/shop" "https://git.example.com/team/app.git git.example.com/team/app"; do
  set -- $pair
  git -C "$T/slug" remote set-url origin "$1"
  : >"$FAKE_GH/calls"
  (unset GH_REPO; cd "$T/slug" && "$BASH_BIN" "$QA" add 1) >/dev/null 2>&1
  has "$1 gives $2" "$(cat "$FAKE_GH/calls")" "-R $2 "
done
git -C "$T/slug" remote set-url origin "$T/remote.git"
out=$(unset GH_REPO; cd "$T/slug" && "$BASH_BIN" "$QA" add 1 2>&1); code=$?
is "a local remote without GH_REPO is refused" "$code" 2
has "it says to set GH_REPO" "$out" "set GH_REPO=owner/repo"

echo "# guard"
guard() { # guard <cwd> <command>
  jq -nc --arg c "$2" --arg d "$1" '{session_id: "s1", cwd: $d, tool_name: "Bash", tool_input: {command: $c}}' | "$BASH_BIN" "$GUARD"
}
denied() { case "$(guard "$2" "$3")" in *'"permissionDecision":"deny"'*) ok "$1" ;; *) nok "$1" "allowed: $3" ;; esac; }
allowed() { local o; o=$(guard "$2" "$3"); if [ -z "$o" ]; then ok "$1"; else nok "$1" "$o"; fi; }
qa add 1 >/dev/null
qa owner Alice >/dev/null
git -C "$W" worktree add -q "$T/wt" -b feat-a origin/feat-a
git -C "$W" worktree add -q --detach "$T/det" origin/feat-a
denied "push of the integration branch" "$W" "git push origin qa-integration"
denied "push of HEAD while on it" "$W" "git push origin HEAD"
denied "bare push while on it" "$W" "git push"
denied "push of it to another name" "$W" "git push origin qa-integration:refs/heads/tmp"
denied "push of the current branch by command substitution" "$W" 'git push -u origin $(git branch --show-current)'
denied "push of @" "$W" "git push origin @"
denied "push of @ to another name" "$W" "git push origin @:refs/heads/tmp"
denied "push of a relative ref" "$W" "git push origin qa-integration~0:refs/heads/tmp"
denied "push of HEAD~0" "$W" "git push origin HEAD~0:refs/heads/tmp"
denied "push of @~0" "$W" "git push origin @~0:refs/heads/tmp"
denied "push of HEAD^0" "$W" "git push origin HEAD^0:refs/heads/tmp"
denied "push of a whole variable" "$W" 'git push origin "$BRANCH"'
allowed "push of a tag name built from a variable" "$W" 'git push origin "v$VERSION"'
allowed "push of a tag ref built from a variable" "$W" 'git push origin "refs/tags/$TAG"'
denied "push of the -prev copy" "$W" "git push origin qa-integration-prev"
denied "push inside bash -c" "$T" "bash -c \"cd $W && git push origin qa-integration\""
denied "push inside sh -c" "$W" "sh -c 'git push origin qa-integration'"
denied "push through eval" "$W" "eval git push origin qa-integration"
denied "push --all" "$W" "git push --all origin"
denied "the override doesn't cover pushing it" "$W" "QA_BRANCH_ALLOW=1 git push origin qa-integration"
allowed "push of a PR branch" "$W" "git push origin feat-a"
allowed "deleting a pushed copy" "$W" "git push origin --delete qa-integration"
denied "force-push of a queued branch" "$W" "git push --force origin feat-a"
denied "force-push with +refspec" "$W" "git push origin +feat-a"
denied "force-with-lease" "$W" "git push --force-with-lease origin feat-a"
denied "force-push from a worktree to refs/heads/<queued>" "$T/wt" "git push -f origin HEAD:refs/heads/feat-a"
denied "force-push of the current branch by command substitution" "$T/wt" 'git push -f origin $(git branch --show-current)'
denied "force-push inside bash -c" "$T/wt" "bash -c 'git push -f origin feat-a'"
denied "force-push from a detached worktree" "$T/det" "git push -f origin HEAD:feat-a"
allowed "plain push from a detached worktree (the carry recipe)" "$T/det" "git push origin HEAD:feat-a"
denied "a later segment is checked" "$W" "git status && git push -uf origin feat-a"
denied "line continuations are joined" "$W" "git push -f \\
  origin feat-a"
allowed "force-push of a branch that isn't queued" "$W" "git push --force origin feat-a-v2"
allowed "the override lets one force-push through" "$W" "QA_BRANCH_ALLOW=1 git push --force origin feat-a"
denied "the override must lead the command" "$W" "git push --force origin feat-a QA_BRANCH_ALLOW=1"
allowed "text that only mentions git" "$W" "echo 'git push origin qa-integration'"
denied "checkout of another branch in the main checkout" "$W" "git checkout main"
denied "switch" "$W" "git switch feat-b"
denied "checkout -b" "$W" "git checkout -b scratch"
denied "checkout -" "$W" "git checkout -"
denied "git -C from elsewhere" "$T" "git -C $W checkout main"
denied "cd, then checkout" "$T" "cd $W && git checkout main"
allowed "file checkout with --" "$W" "git checkout -- a.txt"
allowed "file checkout without --" "$W" "git checkout a.txt"
denied "checkout of a branch that exists only on the remote" "$W" "git checkout feat-b"
denied "checkout --guess of a remote-only branch" "$W" "git checkout --guess feat-b"
allowed "checkout of the integration branch itself" "$W" "git checkout qa-integration"
allowed "a linked worktree may switch" "$T/wt" "git checkout -b other"
allowed "the override lets one switch through" "$W" "QA_BRANCH_ALLOW=1 git checkout main"
denied "reset --hard by any agent session" "$W" "git reset --hard HEAD"
allowed "reset --hard when the person asked" "$W" "QA_BRANCH_ALLOW=1 git reset --hard HEAD"
allowed "a plain reset" "$W" "git reset HEAD a.txt"
denied "stash" "$W" "git stash"
allowed "stash list" "$W" "git stash list"
has "the deny names who is testing" "$(guard "$W" "git checkout main" | jq -r .hookSpecificOutput.permissionDecisionReason)" "Alice is testing"
qa release >/dev/null
allowed "switching is free once the lock is released" "$W" "git checkout main"
allowed "repos without init are left alone" "$T/seed" "git push --force origin qa-integration"
allowed "commands without git" "$W" "ls -la"
has "the deny names the PR" "$(guard "$W" "git push --force origin feat-a" | jq -r .hookSpecificOutput.permissionDecisionReason)" "PR #1"
denied "the guard reads .qa/config" "$T/conf" "git push origin qa-alt"
allowed "and guards that name only" "$T/conf" "git push origin qa-integration"
out=$(jq -nc --arg d "$T/conf" '{cwd: $d, tool_input: {command: "git push origin qa-env"}}' |
  INTEGRATION_BRANCH_QA_INTEGRATION_BRANCH=qa-env "$BASH_BIN" "$GUARD")
has "an env var wins over .qa/config in the guard too" "$out" '"deny"'

mkdir "$T/nojq"
for t in cat sed head; do ln -s "$(command -v "$t")" "$T/nojq/$t"; done
in=$(jq -nc --arg d "$W" '{session_id: "s-nojq", cwd: $d, tool_input: {command: "git push origin qa-integration"}}')
o1=$(printf '%s' "$in" | PATH="$T/nojq" "$BASH_BIN" "$GUARD")
o2=$(printf '%s' "$in" | PATH="$T/nojq" "$BASH_BIN" "$GUARD")
has "without jq the guard allows and says why" "$o1" "jq is not installed"
is "it says so once per session" "$o2" ""
printf '%s' "$o1" | jq -e .systemMessage >/dev/null && ok "the notice is valid JSON" || nok "the notice is valid JSON" "$o1"

echo "# checklist server (node --test)"
node --test "$HERE/checklist-server.test.mjs" >"$T/node.out" 2>&1
code=$?
grep -E '^[^ ]+ (tests|pass|fail) [0-9]+$' "$T/node.out" | sed 's/^[^ ]* /      node: /'
if [ "$code" -eq 0 ]; then ok "node tests pass"; else nok "node tests pass" "$(cat "$T/node.out")"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
