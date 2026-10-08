#!/usr/bin/env bash
# pr-state.sh: one JSON line with a PR's review state, read in a single GraphQL call.
# Usage: pr-state.sh [--findings] [--parked FILE] OWNER/NAME PR ASKED_AT REVIEWER[,REVIEWER]
#   ASKED_AT is UTC, e.g. 2026-01-31T09:00:00Z (from `date -u +%Y-%m-%dT%H:%M:%SZ`).
#   A reviewer matches with or without the [bot] suffix (REST logins have it, GraphQL ones don't).
#   FILE lists thread ids left open on purpose (one per line, a missing file is empty); they're
#   counted as parked_threads instead of unresolved_reviewer_threads and left out of --findings.
# Default output: pr, state, head, mergeable, review_decision, verdict (the reviewer's latest
# APPROVED or CHANGES_REQUESTED), approved (that verdict is APPROVED, on the head commit, after
# ASKED_AT), unresolved_reviewer_threads (any age), parked_threads, review_ok, and why (what keeps
# review_ok false: not OPEN, not approved, open or parked threads, not MERGEABLE, review_decision
# other than APPROVED or empty). mergeable UNKNOWN is retried twice, PR_STATE_WAIT seconds apart.
# --findings: the reviewer's reviews and PR comments after ASKED_AT, and every unresolved thread
# they started, any age, with reply_to (the first comment's id, the one replies must target).
# More than 100 review threads: exits 1 instead of undercounting.
# shellcheck disable=SC2016  # $owner, $p and friends are GraphQL and jq variables, not shell ones
set -u
die() { echo "pr-state: $*" >&2; exit 2; }
mode=state parked=""
while [ $# -gt 0 ]; do
  case "$1" in
    --findings) mode=findings; shift ;;
    --parked) [ $# -ge 2 ] || die "--parked needs a file"; parked=$2; shift 2 ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
[ $# -eq 4 ] || die "usage: pr-state.sh [--findings] [--parked FILE] OWNER/NAME PR ASKED_AT REVIEWER[,REVIEWER]"
repo=$1 pr=$2 asked=$3 who=$4
printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "bad repo: $repo"
case "$pr" in ''|*[!0-9]*) die "not a PR number: $pr" ;; esac
printf '%s' "$asked" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || die "ASKED_AT must look like 2026-01-31T09:00:00Z"
login='[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?'
printf '%s' "$who" | grep -Eq "^$login(,$login)*\$" || die "bad reviewer: $who"
command -v gh >/dev/null 2>&1 || die "gh not found"
list=$(printf '%s' "$who" | sed 's/\[bot\]//g' | tr ',' '\n' | awk '{printf "%s\"%s\",\"%s[bot]\"", (NR > 1 ? "," : ""), $0, $0}')
pk='[]'
if [ -n "$parked" ] && [ -f "$parked" ]; then
  ids=$(grep -v '^[[:space:]]*$' "$parked")
  if [ -n "$ids" ]; then
    printf '%s\n' "$ids" | grep -Evq '^[A-Za-z0-9_=-]+$' && die "bad thread id in $parked"
    pk='["'$(printf '%s' "$ids" | tr '\n' ',' | sed 's/,/","/g')'"]'
  fi
fi

query='query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){
 state headRefOid mergeable reviewDecision
 reviews(last:100){nodes{author{login} state body submittedAt commit{oid}}}
 comments(last:100){nodes{author{login} body createdAt}}
 reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved
  comments(first:50){nodes{fullDatabaseId author{login} path line body}}}}}}}'
head='def mine: (.author.login // "") as $x | ['"$list"'] | any(.[]; . == $x);
.data.repository.pullRequest as $p
| if $p.reviewThreads.pageInfo.hasNextPage then {error: "more than 100 review threads"} else (
  [$p.reviewThreads.nodes[] | select((.isResolved | not) and (.comments.nodes[0] | mine))] as $all
| [$all[] | select(.id as $i | '"$pk"' | any(.[]; . == $i) | not)] as $t
| (($all | length) - ($t | length)) as $np'
state_jq="$head"'
| ([$p.reviews.nodes[] | select(mine and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))] | last) as $v
| (($v.state // "") == "APPROVED" and $v.commit.oid == $p.headRefOid and $v.submittedAt > "'"$asked"'") as $ok
| ($p.reviewDecision // "") as $d
| [ (if $p.state == "OPEN" then empty else "state \($p.state)" end),
    (if $ok then empty else "no approval from the reviewer on the head commit after the ask" end),
    (if ($t | length) > 0 then "\($t | length) unresolved reviewer threads" else empty end),
    (if $np > 0 then "\($np) parked threads need a decision" else empty end),
    (if $p.mergeable == "MERGEABLE" then empty else "mergeable \($p.mergeable)" end),
    (if $d == "APPROVED" or $d == "" then empty else "review_decision \($d)" end) ] as $why
| {pr: '"$pr"', state: $p.state, head: $p.headRefOid, mergeable: $p.mergeable, review_decision: $d,
   verdict: ($v.state // ""), approved: $ok, unresolved_reviewer_threads: ($t | length),
   parked_threads: $np, review_ok: ($why | length == 0), why: $why}) end | tojson'
findings_jq="$head"'
| {pr: '"$pr"', head: $p.headRefOid,
   verdicts: [$p.reviews.nodes[] | select(mine and .submittedAt > "'"$asked"'")
              | {state, body, submitted_at: .submittedAt, commit: .commit.oid}],
   comments: [$p.comments.nodes[] | select(mine and .createdAt > "'"$asked"'") | {body, created_at: .createdAt}],
   threads: [$t[] | .comments.nodes as $c | {id, reply_to: $c[0].fullDatabaseId, path: $c[0].path,
              line: $c[0].line, comments: [$c[] | {author: .author.login, body}]}]}) end | tojson'
[ "$mode" = state ] && prog=$state_jq || prog=$findings_jq

for try in 1 2 3; do
  # On an HTTP error gh prints the error body on stdout, so nothing is printed unless the call succeeded.
  out=$(gh api graphql -f query="$query" -f owner="${repo%/*}" -f name="${repo#*/}" -F n="$pr" \
    --jq "$prog" 2>/dev/null) || { echo "pr-state: gh api graphql failed for $repo#$pr" >&2; exit 1; }
  case "$out" in '{"error":'*) echo "pr-state: $repo#$pr has more than 100 review threads; check them by hand" >&2; exit 1 ;; esac
  case "$out" in *'"mergeable":"UNKNOWN"'*) [ "$try" -lt 3 ] && { sleep "${PR_STATE_WAIT:-10}"; continue; } ;; esac
  break
done
printf '%s\n' "$out"
