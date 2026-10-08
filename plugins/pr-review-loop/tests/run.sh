#!/usr/bin/env bash
# Tests for watch-reviews.sh and pr-state.sh with a fake gh on PATH. Run: bash tests/run.sh (needs jq).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W="$HERE/../skills/pr-review-loop/scripts/watch-reviews.sh"
P="$HERE/../skills/pr-review-loop/scripts/pr-state.sh"
command -v jq >/dev/null 2>&1 || { echo "tests need jq"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pr-review-loop-test.XXXXXX")
: "${T:?mktemp failed}"
mkdir "$T/bin"
passed=0 failed=0 n=0

# Fake gh: answers `gh api [--paginate] PATH --jq EXPR` and `gh api graphql -f/-F ... --jq EXPR`
# from fixtures in $FAKE_GH_DIR. REST slugs drop the repo prefix and query string
# (pulls-12-reviews); GraphQL uses graphql-<n>. Call k to an endpoint reads <slug>.<k>.json, or the
# newest earlier one. <slug>.<k>.fail makes that call fail the way real gh does: the HTTP error
# body on stdout, a summary on stderr, exit 1. Every call is logged to calls.log with its -f/-F
# flags. When an endpoint reaches call $FAKE_STOP_AFTER it creates $FAKE_GH_DIR/stop.
cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
[ "$1" = api ] || { echo "fake gh: only api is stubbed" >&2; exit 1; }
shift; path="" expr="." n="" flags=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) expr=$2; shift 2 ;;
    -f|-F) case "$2" in query=*) ;; *) flags="$flags $1 $2" ;; esac
           case "$2" in n=*) n=${2#n=} ;; esac; shift 2 ;;
    *) path=$1; shift ;;
  esac
done
d=$FAKE_GH_DIR
echo "$path$flags" >> "$d/calls.log"
if [ "$path" = graphql ]; then slug="graphql-$n"
else slug=$(printf '%s' "${path%%\?*}" | sed 's|^repos/[^/]*/[^/]*/||; s|/|-|g'); fi
k=$(( $(cat "$d/count-$slug" 2>/dev/null || echo 0) + 1 ))
echo "$k" > "$d/count-$slug"
[ "$k" -ge "${FAKE_STOP_AFTER:-999999}" ] && : > "$d/stop"
if [ -e "$d/$slug.$k.fail" ]; then
  printf '{\n  "message": "Bad credentials",\n  "status": "401"\n}\n'
  echo "gh: Bad credentials (HTTP 401)" >&2; exit 1
fi
while [ "$k" -gt 0 ] && [ ! -f "$d/$slug.$k.json" ]; do k=$((k - 1)); done
if [ "$k" -gt 0 ]; then jq -r "$expr" "$d/$slug.$k.json"; else echo '[]' | jq -r "$expr"; fi
EOF
chmod +x "$T/bin/gh"

new_case() { n=$((n + 1)); D="$T/case$n"; mkdir "$D"; }
check() {
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); echo "ok   $1"
  else failed=$((failed + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
nl='
'

# ---- watch-reviews.sh ----
rv() { printf '{"id":%s,"state":"%s","user":{"login":"%s"},"html_url":"https://github.com/o/r/pull/%s#r%s"}' "$1" "$2" "$3" "$4" "$1"; }
cm() { printf '{"id":%s,"user":{"login":"%s"},"html_url":"https://github.com/o/r/pull/%s#c%s"}' "$1" "$2" "$3" "$1"; }
fx() { f="$D/$1"; shift; ( IFS=,; printf '[%s]' "$*" ) > "$f"; }
# run_watch STOP_AFTER ARGS...: run the watcher until the fake gh has answered STOP_AFTER polls.
run_watch() {
  s=$1; shift; rm -f "$D/stop"
  PATH="$T/bin:$PATH" FAKE_GH_DIR="$D" FAKE_STOP_AFTER="$s" \
    bash "$W" --repo o/r --interval 0 --stop-file "$D/stop" "$@" 2>"$D/stderr" | grep -v '^watch-reviews: stop file'
}

new_case  # items already there are a baseline; a later review is reported once
fx pulls-12-reviews.1.json "$(rv 1 COMMENTED rev 12)"
fx pulls-12-reviews.2.json "$(rv 1 COMMENTED rev 12)" "$(rv 2 APPROVED rev 12)"
check "watch: baseline is silent, new review printed once" \
  "#12 review 2 APPROVED rev https://github.com/o/r/pull/12#r2" "$(run_watch 3 12)"

new_case  # all three kinds, two PRs, reviewer filter with a bot login
fx pulls-12-comments.2.json "$(cm 5 rev 12)"
fx issues-12-comments.2.json "$(cm 6 me 12)"
fx issues-13-comments.2.json "$(cm 7 'helper[bot]' 13)"
fx pulls-13-reviews.2.json "$(rv 8 CHANGES_REQUESTED someone 13)"
check "watch: reviewer filter keeps only listed logins" \
  "#12 inline 5 rev https://github.com/o/r/pull/12#c5${nl}#13 comment 7 helper[bot] https://github.com/o/r/pull/13#c7" \
  "$(run_watch 2 --reviewer 'rev,helper[bot]' 12 13)"
calls=$(sort -u "$D/calls.log" | tr '\n' ' ')
check "watch: polls the three endpoints with per_page=100" \
  "repos/o/r/issues/12/comments?per_page=100 repos/o/r/issues/13/comments?per_page=100 repos/o/r/pulls/12/comments?per_page=100 repos/o/r/pulls/12/reviews?per_page=100 repos/o/r/pulls/13/comments?per_page=100 repos/o/r/pulls/13/reviews?per_page=100 " "$calls"

new_case  # a reviewer given without [bot] still matches the REST login with it
fx issues-12-comments.2.json "$(cm 7 'helper[bot]' 12)"
check "watch: --reviewer helper matches REST login helper[bot]" \
  "#12 comment 7 helper[bot] https://github.com/o/r/pull/12#c7" "$(run_watch 2 --reviewer helper 12)"

new_case  # no --reviewer: everyone counts
fx issues-12-comments.2.json "$(cm 6 me 12)"
check "watch: without --reviewer every author is reported" \
  "#12 comment 6 me https://github.com/o/r/pull/12#c6" "$(run_watch 2 12)"

new_case  # --state carries the seen set across a restart
fx pulls-12-reviews.1.json "$(rv 1 COMMENTED rev 12)"
fx pulls-12-reviews.2.json "$(rv 1 COMMENTED rev 12)" "$(rv 2 APPROVED rev 12)"
first=$(run_watch 1 --state "$D/seen" 12)
check "watch: state, first run records the baseline silently" "" "$first"
check "watch: state, restart reports what landed in between" \
  "#12 review 2 APPROVED rev https://github.com/o/r/pull/12#r2" "$(run_watch 2 --state "$D/seen" 12)"
check "watch: state file holds both items" "2" "$(wc -l < "$D/seen" | tr -d ' ')"

new_case  # same fixtures without --state: a restart swallows the gap
fx pulls-12-reviews.1.json "$(rv 1 COMMENTED rev 12)"
fx pulls-12-reviews.2.json "$(rv 1 COMMENTED rev 12)" "$(rv 2 APPROVED rev 12)"
run_watch 1 12 >/dev/null
check "watch: no state, restart takes a fresh baseline" "" "$(run_watch 2 12)"

new_case  # a failed call must not make old items look new afterwards
fx pulls-12-reviews.1.json "$(rv 1 COMMENTED rev 12)"
: > "$D/pulls-12-reviews.2.fail"
check "watch: one failed poll causes no replay and no warning" "" "$(run_watch 3 12)"

new_case  # gh prints the HTTP error body on stdout; none of it may become an event or state
fx pulls-12-reviews.1.json "$(rv 1 COMMENTED rev 12)"
: > "$D/pulls-12-reviews.2.fail"
fx pulls-12-reviews.3.json "$(rv 1 COMMENTED rev 12)" "$(rv 2 APPROVED rev 12)"
check "watch: error body is not reported as events" \
  "#12 review 2 APPROVED rev https://github.com/o/r/pull/12#r2" "$(run_watch 3 --state "$D/seen" 12)"
check "watch: error body is not stored in the state file" "0" "$(grep -c 'message\|status\|^[{}]' "$D/seen")"

new_case  # failure reporting: first poll, then once per streak of 3
: > "$D/pulls-12-reviews.1.fail"
check "watch: failure on the first poll is reported" \
  "watch-reviews: gh api failed (auth, network or rate limit), still trying" "$(run_watch 1 12)"
new_case
for k in 2 3 4 5; do : > "$D/pulls-12-reviews.$k.fail"; done
check "watch: 3 failures in a row reported once" "1" "$(run_watch 5 12 | grep -c 'gh api failed')"

new_case  # --exit-on-new: stop after the first batch of new lines
fx pulls-12-reviews.3.json "$(rv 2 APPROVED rev 12)"
out=$(PATH="$T/bin:$PATH" FAKE_GH_DIR="$D" bash "$W" --repo o/r --interval 0 --exit-on-new 12 2>&1); code=$?
check "watch: --exit-on-new prints the batch and exits 0" \
  "#12 review 2 APPROVED rev https://github.com/o/r/pull/12#r2|0" "$out|$code"
check "watch: --exit-on-new stops at that poll" "3" "$(cat "$D/count-pulls-12-reviews")"

new_case  # timeout and stop file
out=$(PATH="$T/bin:$PATH" FAKE_GH_DIR="$D" bash "$W" --repo o/r --interval 1 --timeout 2 12 2>&1); code=$?
check "watch: timeout prints a re-arm line and exits 0" "watch-reviews: timed out after 2s, re-arm to keep watching|0" "$out|$code"
: > "$D/stop"
out=$(PATH="$T/bin:$PATH" FAKE_GH_DIR="$D" bash "$W" --repo o/r --interval 0 --stop-file "$D/stop" 12 2>&1); code=$?
check "watch: stop file ends the watch with exit 0" "watch-reviews: stop file found, exiting|0" "$out|$code"

new_case  # bad arguments exit 2 without polling
for args in "12" "--repo o/r" "--repo o/r 12a" "--repo o/r --interval x 12" "--repo 'o r' 12" \
            '--repo o/r --reviewer a\"b 12' "--repo o/r --bogus 12" "--repo"; do
  eval "set -- $args"
  PATH="$T/bin:$PATH" FAKE_GH_DIR="$D" bash "$W" "$@" >/dev/null 2>&1; code=$?
  check "watch: bad args exit 2: $args" "2" "$code"
done
check "watch: bad args never call gh" "0" "$(cat "$D/calls.log" 2>/dev/null | wc -l | tr -d ' ')"

# A PATH with only the tools the script needs before its gh check. Linux runners keep gh in /usr/bin.
mkdir "$T/nogh"; ln -s "$(command -v grep)" "$T/nogh/grep"
out=$(PATH="$T/nogh" /bin/bash "$W" --repo o/r 12 2>&1); code=$?
check "watch: missing gh is reported on stdout, exit 2" "watch-reviews: gh not found, nothing to watch|2" "$out|$code"

# ---- pr-state.sh ----
ASK=2026-01-10T10:00:00Z BEFORE=2026-01-09T10:00:00Z AFTER=2026-01-10T11:00:00Z LATER=2026-01-10T12:00:00Z
# gq FILE STATE HEAD MERGEABLE DECISION REVIEWS THREADS COMMENTS: write a GraphQL response.
# DECISION null writes a JSON null, as GitHub returns on repos without required reviews.
# NEXT=true marks the threads as having another page (more than 100).
gq() {
  dec="\"$5\""; [ "$5" = null ] && dec=null
  printf '{"data":{"repository":{"pullRequest":{"state":"%s","headRefOid":"%s","mergeable":"%s","reviewDecision":%s,"reviews":{"nodes":[%s]},"comments":{"nodes":[%s]},"reviewThreads":{"pageInfo":{"hasNextPage":%s},"nodes":[%s]}}}}}' \
    "$2" "$3" "$4" "$dec" "$6" "$8" "${NEXT:-false}" "$7" > "$D/$1"
}
gr() { printf '{"author":{"login":"%s"},"state":"%s","submittedAt":"%s","commit":{"oid":"%s"},"body":"%s"}' "$@"; }
gc() { printf '{"author":{"login":"%s"},"createdAt":"%s","body":"%s"}' "$@"; }
# gt ID RESOLVED FIRST_COMMENT_ID LOGIN BODY: fullDatabaseId is a BigInt, a string on the wire.
gt() { printf '{"id":"%s","isResolved":%s,"comments":{"nodes":[{"fullDatabaseId":"%s","author":{"login":"%s"},"path":"a.js","line":3,"body":"%s"},{"fullDatabaseId":"%s","author":{"login":"me"},"path":"a.js","line":3,"body":"reply"}]}}' "$1" "$2" "$3" "$4" "$5" "$(($3 + 1))"; }
run_state() { PATH="$T/bin:$PATH" FAKE_GH_DIR="$D" PR_STATE_WAIT=0 bash "$P" "$@" 2>"$D/stderr"; }
field() { printf '%s' "$1" | jq -c "$2"; }

new_case  # UNKNOWN then MERGEABLE, null reviewDecision, approval on head after the ask
gq graphql-12.1.json OPEN h2 UNKNOWN null "$(gr rev APPROVED "$AFTER" h2 ok)" "" ""
gq graphql-12.2.json OPEN h2 MERGEABLE null "$(gr rev APPROVED "$AFTER" h2 ok)" "" ""
out=$(run_state o/r 12 "$ASK" rev)
check "state: UNKNOWN is retried until MERGEABLE" '"MERGEABLE"|2' "$(field "$out" .mergeable)|$(cat "$D/count-graphql-12")"
check "state: null reviewDecision reads as empty and still allows review_ok" '""|true|true' \
  "$(field "$out" .review_decision)|$(field "$out" .approved)|$(field "$out" .review_ok)"
check "state: one JSON line" "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check "state: owner and name sent with -f, the number with -F" "graphql -f owner=o -f name=r -F n=12" "$(head -1 "$D/calls.log")"

new_case  # UNKNOWN that never settles
gq graphql-12.1.json OPEN h2 UNKNOWN APPROVED "$(gr rev APPROVED "$AFTER" h2 ok)" "" ""
out=$(run_state o/r 12 "$ASK" rev)
check "state: UNKNOWN after 3 tries stays UNKNOWN, not review_ok" '"UNKNOWN"|false|3' \
  "$(field "$out" .mergeable)|$(field "$out" .review_ok)|$(cat "$D/count-graphql-12")"

new_case  # an unresolved reviewer thread from before the ask still counts
threads="$(gt T1 false 3000000001 rev 'old finding'),$(gt T2 true 601 rev 'fixed'),$(gt T3 false 701 other 'not the reviewer')"
gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr rev APPROVED "$AFTER" h2 ok)" "$threads" ""
out=$(run_state o/r 12 "$ASK" rev)
check "state: old unresolved reviewer thread counts, blocks review_ok" "1|false" \
  "$(field "$out" .unresolved_reviewer_threads)|$(field "$out" .review_ok)"
out=$(run_state --findings o/r 12 "$ASK" rev)
check "findings: lists it with the first comment's 64-bit id, as a string, in reply_to" \
  '[{"id":"T1","reply_to":"3000000001","body":"old finding","n":2}]' \
  "$(field "$out" '[.threads[] | {id, reply_to, body: .comments[0].body, n: (.comments | length)}]')"
printf 'T1\n\n' > "$D/parked"
out=$(run_state --parked "$D/parked" o/r 12 "$ASK" rev)
check "state: a parked thread moves to parked_threads and still blocks review_ok" "0|1|false" \
  "$(field "$out" .unresolved_reviewer_threads)|$(field "$out" .parked_threads)|$(field "$out" .review_ok)"
check "state: why names the parked thread" '["1 parked threads need a decision"]' "$(field "$out" .why)"
check "findings: a parked thread is left out" "0" "$(field "$(run_state --findings --parked "$D/parked" o/r 12 "$ASK" rev)" '.threads | length')"
check "state: a missing parked file counts as empty" "1" "$(field "$(run_state --parked "$D/none" o/r 12 "$ASK" rev)" .unresolved_reviewer_threads)"
printf 'T1; rm -rf /\n' > "$D/badparked"
run_state --parked "$D/badparked" o/r 12 "$ASK" rev >/dev/null; code=$?
check "state: a bad thread id in the parked file exits 2" "2" "$code"

new_case  # approve, then a plain COMMENTED review: still approved
gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr rev APPROVED "$AFTER" h2 ok),$(gr rev COMMENTED "$LATER" h2 nit)" "" ""
out=$(run_state o/r 12 "$ASK" rev)
check "state: approve then comment keeps the approval" '"APPROVED"|true|true' \
  "$(field "$out" .verdict)|$(field "$out" .approved)|$(field "$out" .review_ok)"

new_case  # approve, then request changes: not approved
gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr rev APPROVED "$AFTER" h2 ok),$(gr rev CHANGES_REQUESTED "$LATER" h2 no)" "" ""
out=$(run_state o/r 12 "$ASK" rev)
check "state: a later CHANGES_REQUESTED wins" '"CHANGES_REQUESTED"|false' "$(field "$out" .verdict)|$(field "$out" .approved)"

new_case  # approval on an older commit, or before the ask, doesn't count
gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr rev APPROVED "$AFTER" h1 ok)" "" ""
check "state: approval on an older commit is not approved" "false" "$(field "$(run_state o/r 12 "$ASK" rev)" .approved)"
new_case
gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr rev APPROVED "$BEFORE" h2 ok)" "" ""
check "state: approval before the ask is not approved" "false" "$(field "$(run_state o/r 12 "$ASK" rev)" .approved)"

new_case  # someone else's approval doesn't count; a second listed login does
gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr other APPROVED "$AFTER" h2 ok)" "" ""
check "state: another author's approval is ignored" "false" "$(field "$(run_state o/r 12 "$ASK" rev)" .approved)"
check "state: a comma list of logins is accepted" "true" "$(field "$(run_state o/r 12 "$ASK" rev,other)" .approved)"

new_case  # GraphQL bot logins have no [bot] suffix; the reviewer may be given either way
gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr helper APPROVED "$AFTER" h2 ok)" "$(gt T9 false 900 helper 'bot finding')" ""
out=$(run_state o/r 12 "$ASK" 'helper[bot]')
check "state: reviewer helper[bot] matches GraphQL login helper" "true|1" \
  "$(field "$out" .approved)|$(field "$out" .unresolved_reviewer_threads)"
check "state: reviewer helper matches too" "true" "$(field "$(run_state o/r 12 "$ASK" helper)" .approved)"

new_case  # branch protection still wants reviews, or a conflict
gq graphql-12.1.json OPEN h2 MERGEABLE REVIEW_REQUIRED "$(gr rev APPROVED "$AFTER" h2 ok)" "" ""
out=$(run_state o/r 12 "$ASK" rev)
check "state: REVIEW_REQUIRED blocks review_ok and says why" 'true|false|["review_decision REVIEW_REQUIRED"]' \
  "$(field "$out" .approved)|$(field "$out" .review_ok)|$(field "$out" .why)"
new_case
gq graphql-12.1.json OPEN h2 CONFLICTING APPROVED "$(gr rev APPROVED "$AFTER" h2 ok)" "" ""
out=$(run_state o/r 12 "$ASK" rev)
check "state: CONFLICTING is reported at once, no retry" '"CONFLICTING"|false|1' \
  "$(field "$out" .mergeable)|$(field "$out" .review_ok)|$(cat "$D/count-graphql-12")"

new_case  # findings: verdicts and PR comments after the ask, from the reviewer only
gq graphql-12.1.json OPEN h2 MERGEABLE CHANGES_REQUESTED \
  "$(gr rev COMMENTED "$BEFORE" h1 old),$(gr rev CHANGES_REQUESTED "$AFTER" h2 fix),$(gr other APPROVED "$AFTER" h2 lgtm)" "" \
  "$(gc rev "$BEFORE" stale),$(gc rev "$AFTER" 'blocked by X'),$(gc other "$AFTER" hi)"
out=$(run_state --findings o/r 12 "$ASK" rev)
check "findings: only the reviewer's verdicts after the ask" '["CHANGES_REQUESTED:fix"]' "$(field "$out" '[.verdicts[] | "\(.state):\(.body)"]')"
check "findings: only the reviewer's PR comments after the ask" '["blocked by X"]' "$(field "$out" '[.comments[].body]')"

new_case  # more than 100 threads: fail loudly instead of undercounting
NEXT=true gq graphql-12.1.json OPEN h2 MERGEABLE APPROVED "$(gr rev APPROVED "$AFTER" h2 ok)" "" ""
out=$(run_state o/r 12 "$ASK" rev); code=$?
check "state: over 100 threads prints nothing and exits 1" "|1" "$out|$code"
check "state: over 100 threads says so on stderr" "1" "$(grep -c 'more than 100 review threads' "$D/stderr")"
check "findings: over 100 threads exits 1 too" "1" "$(run_state --findings o/r 12 "$ASK" rev >/dev/null; echo $?)"

new_case  # gh failure: nothing on stdout (the error body is dropped), exit 1
: > "$D/graphql-12.1.fail"
out=$(run_state o/r 12 "$ASK" rev); code=$?
check "state: gh failure prints nothing and exits 1" "|1" "$out|$code"

new_case  # bad arguments exit 2 without calling gh
for args in "o/r 12 $ASK" "--parked" "--bogus o/r 12 $ASK rev" "o/r 12a $ASK rev" "o/r 12 2026-01-10 rev" "o/r 12 $ASK 'a\"b'" "'o r' 12 $ASK rev"; do
  eval "set -- $args"
  run_state "$@" >/dev/null; code=$?
  check "state: bad args exit 2: $args" "2" "$code"
done
check "state: bad args never call gh" "0" "$(cat "$D/calls.log" 2>/dev/null | wc -l | tr -d ' ')"

rm -rf "${T:?}"
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
