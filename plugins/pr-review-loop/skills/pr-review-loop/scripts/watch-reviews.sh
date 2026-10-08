#!/usr/bin/env bash
# watch-reviews.sh: print one line per new PR review, inline review comment or PR comment.
# Usage: watch-reviews.sh --repo OWNER/NAME [--reviewer LOGIN[,LOGIN]] [--interval 60]
#          [--timeout 1740] [--state FILE] [--stop-file FILE] [--exit-on-new] PR [PR ...]
# Items that exist on the first pass are recorded silently. There is no time filter: a line is
# new when it isn't in the seen set. --state keeps that set in FILE, so a re-armed watcher still
# reports what landed while it was down. Exits on the stop file, on timeout, or after the first
# batch of new lines with --exit-on-new (for runners that only wake you when a command exits).
set -u
export LC_ALL=C
die() { echo "watch-reviews: $*" >&2; exit 2; }
repo="" reviewer="" interval=60 timeout=1740 state="" stop="" once=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--reviewer|--interval|--timeout|--state|--stop-file) [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in --repo) repo=$2 ;; --reviewer) reviewer=$2 ;; --interval) interval=$2 ;;
        --timeout) timeout=$2 ;; --state) state=$2 ;; --stop-file) stop=$2 ;; esac
      shift 2 ;;
    --exit-on-new) once=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
[ -n "$repo" ] && [ $# -gt 0 ] || die "usage: watch-reviews.sh --repo OWNER/NAME [options] PR [PR ...]"
printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "bad --repo: $repo"
for v in "$@" "$interval" "$timeout"; do case "$v" in ''|*[!0-9]*) die "not a whole number: $v" ;; esac; done
sel=true login='[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?'
if [ -n "$reviewer" ]; then
  printf '%s' "$reviewer" | grep -Eq "^$login(,$login)*\$" || die "bad --reviewer: $reviewer"
  # A login matches with or without the [bot] suffix that REST adds to bot accounts.
  sel=$(printf '%s' "$reviewer" | sed 's/\[bot\]//g; s/[^,][^,]*/.user.login == "&" or .user.login == "&[bot]"/g; s/,/ or /g')
fi
command -v gh >/dev/null 2>&1 || { echo "watch-reviews: gh not found, nothing to watch"; exit 2; }

get() {  # get PATH PREFIX: print the items' lines, only when the call succeeded
  # On an HTTP error gh prints the error body on stdout, so a failed call's output is dropped.
  out=$(gh api --paginate "repos/$repo/$1?per_page=100" \
    --jq ".[] | select($sel) | \"$2 \(.user.login) \(.html_url)\"" 2>/dev/null) || return 1
  [ -z "$out" ] || printf '%s\n' "$out"
}
snap() {  # one line per item on every watched PR; fails if any call failed
  rc=0
  for n in "$@"; do
    get "pulls/$n/reviews" "#$n review \(.id) \(.state)" || rc=1
    get "pulls/$n/comments" "#$n inline \(.id)" || rc=1
    get "issues/$n/comments" "#$n comment \(.id)" || rc=1
  done
  return $rc
}

seen="" primed="" fails=0 polls=0 start=$(date +%s)
[ -n "$state" ] && [ -f "$state" ] && { seen=$(cat "$state"); primed=1; }
while :; do
  if cur=$(snap "$@"); then fails=0; else
    fails=$((fails + 1))  # say so on the first poll and after 3 failures in a row
    if [ "$polls" -eq 0 ] || [ "$fails" -eq 3 ]; then echo "watch-reviews: gh api failed (auth, network or rate limit), still trying"; fi
  fi
  polls=$((polls + 1)) new=""
  if [ -n "$primed" ]; then
    new=$(printf '%s\n' "$cur" | sort -u | comm -13 <(printf '%s\n' "$seen" | sort -u) - | grep -v '^$')
    [ -n "$new" ] && printf '%s\n' "$new"
  fi
  # Keep the union, so an item missing from one failed poll isn't reported again later.
  seen=$(printf '%s\n%s\n' "$seen" "$cur" | sort -u | grep -v '^$') primed=1
  [ -n "$state" ] && printf '%s\n' "$seen" > "$state"
  [ -n "$once" ] && [ -n "$new" ] && exit 0
  [ -n "$stop" ] && [ -e "$stop" ] && { echo "watch-reviews: stop file found, exiting"; exit 0; }
  if [ $(( $(date +%s) - start + interval )) -ge "$timeout" ]; then
    echo "watch-reviews: timed out after ${timeout}s, re-arm to keep watching"; exit 0
  fi
  sleep "$interval"
done
