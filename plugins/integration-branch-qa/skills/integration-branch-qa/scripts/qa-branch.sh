#!/usr/bin/env bash
# qa-branch.sh: test several PRs at once on a local integration branch, built
# from <remote>/<base> plus every queued PR, each merged with --no-ff. The
# branch is never pushed and never merged; each PR merges from its own branch.
#
#   init [--base B] [--branch I] [--remote R] [--dir D] [--port P]
#   add <pr> | remove <pr> [--force] | rebuild [--allow-stranded] | status
#   check-pr <pr> | checklist | owner [<who>] | release
#
# Settings: INTEGRATION_BRANCH_QA_<KEY> env var, then .qa/config (written by
# init), then the default. GH_REPO=owner/repo overrides the repo from the URL.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PLACEHOLDER="Replace with 1 to 3 things to check by hand, and what should happen"
FAILS=0

die() { printf 'qa-branch: %s\n' "$*" >&2; exit 2; }
warn() { printf 'qa-branch: %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required to $2"; }
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "$1"; }
g() { git -C "$MAIN" "$@"; }
has_ref() { g rev-parse --verify --quiet "$1" >/dev/null; }
short() { g rev-parse --short "$1"; }
# Never prints an empty path: callers rm -rf what it returns.
mktmp() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/qa-branch.XXXXXX") && [ -n "$d" ] || die "could not create a temp folder"
  printf '%s\n' "$d"
}
fetch() { g fetch --quiet --prune "$REMOTE" 2>/dev/null || warn "fetch from $REMOTE failed; using the refs already here"; }
pr_num() { local n="${1#\#}"; case "$n" in '' | *[!0-9]*) return 1 ;; esac; printf '%s' "$n"; }
pass() { printf '  PASS  %s\n' "$*"; }
flag() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
lock_line() { if [ -f "$LOCK" ]; then echo "lock: $(sed -n 's/^owner //p' "$LOCK") is testing (since $(sed -n 's/^since //p' "$LOCK"))"; else echo "lock: free"; fi; }

# setting <key> <default>: env var, then .qa/config in the main checkout, then the default.
setting() {
  local v
  eval "v=\${INTEGRATION_BRANCH_QA_$(printf '%s' "$1" | tr a-z A-Z):-}"
  [ -n "$v" ] || v=$(sed -n "s/^$1=//p" "$MAIN/.qa/config" 2>/dev/null | tail -n 1)
  printf '%s' "${v:-$2}"
}

# The main worktree is where the dev servers run and where .qa lives, so every
# command works the same from any linked worktree of the repo.
setup_repo() {
  command -v git >/dev/null 2>&1 || die "git is required"
  MAIN=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$MAIN" ] || die "run this inside a git repository"
  BASE=$(setting base_branch main) INT=$(setting integration_branch qa-integration)
  REMOTE=$(setting remote origin) QA_DIR=$(setting qa_dir .qa) PORT=$(setting checklist_port 4777)
  paths
}
# Every rebuild rewrites the integration branch, so it must never name a real branch.
safe_int() { case "$INT" in "$BASE" | main | master | '') die "the integration branch can't be '$INT', because rebuild rewrites it. Pick another name: init --branch <name>" ;; esac; }
paths() {
  case "$QA_DIR" in /*) QD=$QA_DIR ;; *) QD="$MAIN/$QA_DIR" ;; esac
  QUEUE="$QD/queue.md" CHECKLIST="$QD/checklist.md" LOCK="$QD/lock" BASEREF="$REMOTE/$BASE"
}

# "<pr> <branch>" lines from the qa-queue block of the queue file, in order.
queue_entries() {
  [ -f "$QUEUE" ] || return 0
  awk '/^```qa-queue/ { on = 1; next } on && /^```/ { on = 0 }
    on && NF >= 2 { sub(/^#/, "", $1); if ($1 ~ /^[0-9]+$/) print $1, $2 }' "$QUEUE"
}

# owner/repo for gh: GH_REPO, else the remote's URL (host/owner/repo off github.com).
gh_repo() {
  local r
  [ -n "${GH_REPO:-}" ] && { printf '%s' "$GH_REPO"; return 0; }
  r=$(g remote get-url "$REMOTE" 2>/dev/null | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##;
    s#^([^:/]+):[0-9]*/#\1/#; s#^([^:/]+):#\1/#; s#/$##; s#\.git$##; s#^github\.com/##')
  case "$r" in [!/]*/*) printf '%s' "$r" ;; *) die "can't tell the GitHub repo from $REMOTE's URL; set GH_REPO=owner/repo" ;; esac
}

# patch-ids (one per line) of the non-merge commits in the given ranges.
patch_ids() { g log --no-merges -p "$@" | g patch-id --stable | cut -d' ' -f1; }

# Is commit $1's change already on one of the refs $2...? Either a commit with
# the same diff is listed in $PIDS (patch-id, so a cherry-pick counts), or its
# diff reverse-applies cleanly to the ref's tree (the content landed another way).
covered() {
  local c="$1" ref idx
  shift
  [ -n "$(g diff --name-only "$c^" "$c")" ] || return 0 # an empty commit changes nothing to test
  grep -qxF -- "$(g show "$c" | g patch-id --stable | cut -d' ' -f1)" "$PIDS" && return 0
  for ref in "$@"; do
    idx=$(mktemp "${TMPDIR:-/tmp}/qa-index.XXXXXX")
    if GIT_INDEX_FILE="$idx" g read-tree "$ref" 2>/dev/null &&
      g diff --binary "$c^" "$c" | GIT_INDEX_FILE="$idx" g apply --cached --check -R - 2>/dev/null; then
      rm -f "$idx"; return 0
    fi
    rm -f "$idx"
  done
  return 1
}

# Commits only on the integration branch: not reachable from the base or a
# queued branch, and not carried to a queued branch. A rebuild drops them.
stranded() {
  local refs="$BASEREF" b tmp c
  has_ref "refs/heads/$INT" || return 0
  tmp=$(mktmp) || exit 2
  PIDS="$tmp/pids"
  : >"$PIDS"
  for b in $(queue_entries | awk '{ print $2 }'); do
    has_ref "refs/remotes/$REMOTE/$b" || continue
    refs="$refs $REMOTE/$b"
    patch_ids "$BASEREF..$REMOTE/$b" >>"$PIDS"
  done
  # shellcheck disable=SC2086
  g rev-list --no-merges "$INT" --not $refs | while read -r c; do
    # shellcheck disable=SC2086
    covered "$c" $refs || g log -1 --format='%h %s' "$c"
  done
  rm -rf "${tmp:?}"
}

# Commits on ref $1 whose change is not on the integration branch yet.
untested() {
  local tmp c
  tmp=$(mktmp) || exit 2
  PIDS="$tmp/pids"
  patch_ids "$BASEREF..$INT" >"$PIDS"
  g rev-list --no-merges "$INT..$1" | while read -r c; do
    covered "$c" "$INT" || g log -1 --format='%h %s' "$c"
  done
  rm -rf "${tmp:?}"
}

# State of queued branch $1 against the integration branch.
entry_state() {
  local ref="$REMOTE/$1" own miss n
  has_ref "refs/remotes/$ref" || { echo "GONE ($ref no longer exists: merged and deleted?)"; return; }
  has_ref "refs/heads/$INT" || { echo "NOT IN (run rebuild)"; return; }
  if g merge-base --is-ancestor "$ref" "$INT"; then echo "IN @ $(short "$ref")"; return; fi
  own=$(g rev-list --count "$BASEREF..$ref")
  miss=$(g rev-list --count "$ref" --not "$BASEREF" "$INT")
  if [ "$miss" -ge "$own" ]; then echo "NOT IN (run rebuild)"; return; fi
  n=$(untested "$ref" | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "MOVED @ $(short "$ref"), its new changes are already on $INT (rebuild to record it)"
  else
    echo "MOVED @ $(short "$ref"), $n commit(s) not on $INT yet (rebuild, then retest)"
  fi
}

# "<unticked> <total> <placeholders>" for the checklist sections whose heading
# names #<pr>, NOSECTION when no heading does, NOFILE when there's no checklist.
checklist_count() {
  [ -f "$CHECKLIST" ] || { echo NOFILE; return; }
  awk -v num="$1" -v ph="$PLACEHOLDER" '
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    /^## / { on = ($0 ~ ("#" num "([^0-9]|$)")); if (on) found = 1; next }
    /^# / { on = 0 }
    on && /^[[:space:]]*[-*] \[[ xX]\]/ { total++; if ($0 ~ /^[[:space:]]*[-*] \[ \]/) open++; if (index($0, ph)) held++ }
    END { if (!found) print "NOSECTION"; else print open + 0, total + 0, held + 0 }' "$CHECKLIST"
}

cmd_init() {
  local f d
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --base) BASE=$2 ;; --branch) INT=$2 ;; --remote) REMOTE=$2 ;; --dir) QA_DIR=$2 ;; --port) PORT=$2 ;;
      *) die "init takes --base, --branch, --remote, --dir and --port, not $1" ;;
    esac
    shift 2
  done
  case "$PORT" in '' | *[!0-9]*) die "--port needs a number" ;; esac
  safe_int
  paths
  for d in "$MAIN/.qa" "$QD"; do # a folder init creates also gets a .gitignore, so git ignores it
    [ -d "$d" ] || { mkdir -p "$d" && printf '*\n' >"$d/.gitignore"; } || die "can't create $d"
  done
  printf 'base_branch=%s\nintegration_branch=%s\nremote=%s\nqa_dir=%s\nchecklist_port=%s\n' \
    "$BASE" "$INT" "$REMOTE" "$QA_DIR" "$PORT" >"$MAIN/.qa/config"
  for f in queue checklist; do
    if [ -f "$QD/$f.md" ]; then echo "kept $QD/$f.md"; else cp "$HERE/../templates/$f.md" "$QD/$f.md" && echo "created $QD/$f.md"; fi
  done
  echo "settings saved in $MAIN/.qa/config: base $BASEREF, branch $INT, folder $QD, checklist port $PORT"
  echo "Next: add <pr> for each approved PR, then rebuild."
}

cmd_add() {
  local n repo json b state title fork tmp
  n=$(pr_num "${1:-}") || die "usage: add <pr-number>"
  [ -f "$QUEUE" ] || die "no $QUEUE; run init first"
  grep -q '^```qa-queue' "$QUEUE" || die "$QUEUE has no qa-queue block; copy it back from the template"
  need gh "look up the PR"
  need jq "read gh's answer"
  repo=$(gh_repo) || exit 2
  json=$(gh pr view "$n" -R "$repo" --json headRefName,state,title,isCrossRepository) || die "gh pr view $n failed"
  b=$(printf '%s' "$json" | jq -r '.headRefName // empty')
  state=$(printf '%s' "$json" | jq -r '.state // empty')
  title=$(printf '%s' "$json" | jq -r '.title // ""')
  fork=$(printf '%s' "$json" | jq -r '.isCrossRepository // false')
  [ -n "$b" ] || die "gh returned no branch for #$n"
  [ "$state" = OPEN ] || die "#$n is $state; only open PRs can be queued"
  [ "$fork" = true ] && die "#$n comes from a fork; only PRs whose branch is on $REMOTE can be queued"
  if queue_entries | awk -v n="$n" '$1 == n { f = 1 } END { exit !f }'; then
    echo "#$n is already queued"
  else
    tmp="$QUEUE.tmp.$$"
    awk -v line="$n $b" '/^```qa-queue/ { on = 1; print; next } on && /^```/ { print line; on = 0 } { print }' \
      "$QUEUE" >"$tmp" && mv "$tmp" "$QUEUE"
    echo "queued #$n ($b)"
  fi
  fetch
  has_ref "refs/remotes/$REMOTE/$b" || warn "$REMOTE/$b isn't fetched; rebuild skips it until it is"
  if [ "$(checklist_count "$n")" = NOSECTION ]; then
    printf '\n## #%s: %s\n\n- [ ] %s\n' "$n" "$title" "$PLACEHOLDER" >>"$CHECKLIST"
    echo "added a section for #$n to $CHECKLIST; replace its placeholder with real items"
  fi
  echo "Run rebuild to merge it into $INT."
}

cmd_remove() {
  local n force="${2:-}" b counts tmp
  n=$(pr_num "${1:-}") || die "usage: remove <pr-number> [--force]"
  b=$(queue_entries | awk -v n="$n" '$1 == n { print $2; exit }')
  [ -n "$b" ] || die "#$n is not in the queue"
  counts=$(checklist_count "$n")
  case "$counts" in
    NOFILE | NOSECTION | "0 "*) ;;
    *) [ "$force" = --force ] || die "#$n still has ${counts%% *} unticked checklist item(s). Tick them, or pass --force if the person testing drops it." ;;
  esac
  tmp="$QUEUE.tmp.$$"
  awk -v n="$n" '/^```qa-queue/ { on = 1; print; next } on && /^```/ { on = 0 }
    on { k = $1; sub(/^#/, "", k); if (k == n) next } { print }' "$QUEUE" >"$tmp" && mv "$tmp" "$QUEUE"
  printf -- '- %s: #%s (%s) left the queue\n' "$(date -u +%Y-%m-%d)" "$n" "$b" >>"$QUEUE"
  if [ -f "$CHECKLIST" ]; then
    awk -v num="$n" '/^## / && !fence { drop = ($0 ~ ("#" num "([^0-9]|$)")) }
      /^# / && !fence { drop = 0 } /^[[:space:]]*```/ { fence = !fence } !drop { print }' \
      "$CHECKLIST" >"$CHECKLIST.tmp.$$" && mv "$CHECKLIST.tmp.$$" "$CHECKLIST"
  fi
  echo "removed #$n. Run rebuild so $INT drops it (once merged, it comes back in through $BASEREF)."
}

cmd_rebuild() {
  local allow="${1:-}" gd f s pr b wt wtdir out conflicts
  [ -f "$QUEUE" ] || die "no $QUEUE; run init first"
  safe_int
  [ ! -f "$LOCK" ] || [ "${QA_BRANCH_ALLOW:-}" = 1 ] ||
    die "$(lock_line), so rebuild is on hold. To rebuild now, run QA_BRANCH_ALLOW=1 qa-branch.sh rebuild, or release the lock first. Agents: only when the person testing asks."
  s=$(g status --porcelain -uno)
  [ -z "$s" ] || die "the main checkout ($MAIN) has uncommitted tracked changes; move them to a PR branch or discard them first:
$s"
  gd=$(g rev-parse --git-dir)
  case "$gd" in /*) ;; *) gd="$MAIN/$gd" ;; esac
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ -e "$gd/$f" ] && die "the main checkout has an operation in progress ($f); finish or abort it first"
  done
  fetch
  has_ref "$BASEREF" || die "there is no $BASEREF; check the base and remote settings in $MAIN/.qa/config"
  s=$(stranded)
  [ -z "$s" ] || [ "$allow" = --allow-stranded ] ||
    die "these commits exist only on $INT and a rebuild would drop them. Carry each to its PR branch, or pass --allow-stranded (they stay on $INT-prev):
$s"
  # Merge in a throwaway worktree, so the main checkout (and its dev servers) changes once, at the end.
  wtdir=$(mktmp) || exit 2
  wt="$wtdir/build"
  g worktree add --quiet --detach "$wt" "$BASEREF" || die "could not create a build worktree"
  echo "building $INT from $BASEREF $(short "$BASEREF")"
  while read -r pr b; do
    [ -n "$pr" ] || continue
    if ! has_ref "refs/remotes/$REMOTE/$b"; then
      echo "  skip #$pr: $REMOTE/$b is gone (merged and deleted?); remove it once its checklist is done"
      continue
    fi
    if out=$(git -C "$wt" merge --no-ff --no-edit -m "qa: merge #$pr ($b)" "$REMOTE/$b" 2>&1); then
      echo "  merged #$pr $b @ $(short "$REMOTE/$b")"
      continue
    fi
    conflicts=$(git -C "$wt" diff --name-only --diff-filter=U)
    g worktree remove --force "$wt" && rm -rf "${wtdir:?}"
    [ -n "$conflicts" ] || die "merging #$pr ($b) failed; nothing changed:
$out"
    echo "CONFLICT merging #$pr ($b). $INT and the main checkout are unchanged. Conflicted files:"
    printf '%s\n' "$conflicts" | sed 's/^/  /'
    echo "Resolve it on the PR branch: merge $BASEREF (or the PR it clashes with) into $b in a worktree, push, then rebuild."
    return 1
  done <<EOF
$(queue_entries)
EOF
  s=$(git -C "$wt" rev-parse HEAD)
  g worktree remove --force "$wt" && rm -rf "${wtdir:?}"
  has_ref "refs/heads/$INT" && g branch -f "$INT-prev" "$INT"
  # --no-track: an upstream would make a bare `git push` send the build to the base branch.
  out=$(g checkout --quiet --no-track -B "$INT" "$s" 2>&1) ||
    die "the build is ready ($(short "$s")) but the main checkout can't move to it; $INT is unchanged:
$out"
  g branch --unset-upstream "$INT" 2>/dev/null
  echo "$INT is now $(short "$INT"). Restart the dev servers if they don't reload on their own."
}

cmd_status() {
  local cur dirty pr b s merged
  [ -f "$QUEUE" ] || die "no $QUEUE; run init first"
  fetch
  cur=$(g symbolic-ref -q --short HEAD || echo "a detached HEAD")
  dirty=$(g status --porcelain -uno | wc -l | tr -d ' ')
  echo "main checkout: $MAIN, on $cur, $dirty uncommitted tracked change(s)"
  lock_line
  if has_ref "refs/heads/$INT"; then
    echo "$INT $(short "$INT"): $(g rev-list --count "$INT..$BASEREF") behind $BASEREF, $(g rev-list --count "$BASEREF..$INT") ahead"
    [ "$cur" = "$INT" ] || echo "  the main checkout is not on $INT; rebuild puts it there"
  else
    echo "$INT: not built yet; run rebuild"
  fi
  echo "queue:"
  [ -n "$(queue_entries)" ] || echo "  (empty)"
  while read -r pr b; do
    [ -n "$pr" ] && printf '  #%-6s %-36s %s\n' "$pr" "$b" "$(entry_state "$b")"
  done <<EOF
$(queue_entries)
EOF
  has_ref "refs/heads/$INT" || return 0
  merged=$(g log --merges --first-parent --format=%s "$BASEREF..$INT" | sed -nE 's/^qa: merge #[0-9]+ \((.*)\)$/\1/p' |
    while read -r b; do queue_entries | awk -v b="$b" '$2 == b { f = 1 } END { exit f }' && echo "  $b"; done)
  [ -z "$merged" ] || printf 'merged into %s but no longer queued (the next rebuild drops them):\n%s\n' "$INT" "$merged"
  s=$(stranded)
  if [ -n "$s" ]; then
    echo "STRANDED (only on $INT; carry each to its PR branch before the next rebuild, see SKILL.md):"
    printf '%s\n' "$s" | sed 's/^/  /'
  else
    echo "stranded: none"
  fi
}

cmd_check_pr() {
  local n repo json b head state mergeable base s tmp
  n=$(pr_num "${1:-}") || die "usage: check-pr <pr-number>"
  need gh "ask GitHub about the PR"
  need jq "read gh's answer"
  repo=$(gh_repo) || exit 2
  json=$(gh pr view "$n" -R "$repo" --json headRefName,headRefOid,state,mergeable,baseRefName) ||
    die "gh pr view $n failed"
  b=$(printf '%s' "$json" | jq -r '.headRefName // empty')
  head=$(printf '%s' "$json" | jq -r '.headRefOid // empty')
  state=$(printf '%s' "$json" | jq -r '.state // empty')
  mergeable=$(printf '%s' "$json" | jq -r '.mergeable // empty')
  base=$(printf '%s' "$json" | jq -r '.baseRefName // empty')
  fetch
  echo "#$n $b -> $base, head $(printf '%.8s' "$head") ($state)"
  if [ "$state" = OPEN ]; then pass "the PR is open"; else flag "the PR is ${state:-unknown}"; fi
  [ "$base" = "$BASE" ] || printf '  WARN  it targets %s, but %s is built on %s\n' "$base" "$INT" "$BASE"
  if ! has_ref "refs/heads/$INT"; then
    flag "there is no $INT branch yet (add, rebuild, test)"
  elif ! g cat-file -e "$head^{commit}" 2>/dev/null; then
    flag "head $(printf '%.8s' "$head") isn't fetched; is $b on $REMOTE?"
  elif g merge-base --is-ancestor "$head" "$INT"; then
    pass "$INT holds the PR's current head, so that head was tested"
  else
    s=$(untested "$head")
    if [ -z "$s" ]; then
      pass "the head moved after the last merge-in, but its new changes are already on $INT"
    else
      flag "the head moved; these commits were never on $INT (rebuild, then retest):"
      printf '%s\n' "$s" | sed 's/^/          /'
    fi
  fi
  case "$mergeable" in
    MERGEABLE) pass "GitHub sees no conflict with $base" ;;
    CONFLICTING) flag "it conflicts with $base: merge $REMOTE/$base into $b and resolve it there" ;;
    *) printf '  WARN  GitHub mergeability is %s; run check-pr again in a minute\n' "${mergeable:-unknown}" ;;
  esac
  tmp=$(mktmp) || exit 2
  g diff --name-only "$BASEREF...$head" >"$tmp/files" 2>/dev/null
  s=$(stranded | while read -r c _; do
    g show --name-only --format= "$c" | grep -qxF -f "$tmp/files" && g log -1 --format='%h %s' "$c"
  done)
  rm -rf "${tmp:?}"
  if [ -n "$s" ]; then
    flag "stranded fixes on $INT touch this PR's files (carry them to $b first):"
    printf '%s\n' "$s" | sed 's/^/          /'
  else
    pass "no stranded fix on $INT touches its files"
  fi
  set -- $(checklist_count "$n")
  case "$1" in
    NOFILE) flag "there is no $CHECKLIST" ;;
    NOSECTION) flag "no checklist heading names #$n" ;;
    *) if [ "$2" -eq 0 ]; then flag "its checklist section has no items"
      elif [ "$3" -gt 0 ]; then flag "its checklist section still holds the placeholder item; write real items"
      elif [ "$1" -gt 0 ]; then flag "$1 of $2 checklist item(s) still unticked"
      else pass "its checklist section is fully ticked ($2 item(s))"; fi ;;
  esac
  if [ "$FAILS" -eq 0 ]; then
    echo "RESULT: ready to merge from $b, once the person testing says go"
    return 0
  fi
  echo "RESULT: not ready ($FAILS failing check(s))"
  return 1
}

cmd_checklist() {
  need node "serve the checklist page"
  [ -f "$CHECKLIST" ] || die "no $CHECKLIST; run init first"
  exec node "$HERE/checklist-server.mjs" "$CHECKLIST" --port "$PORT"
}

# The lock is a label naming who is testing. While it exists, the guard hook
# stops agents from switching, resetting or stashing the main checkout, and
# rebuild needs QA_BRANCH_ALLOW=1, given on the person's ask.
cmd_owner() {
  [ -n "${1:-}" ] || { lock_line; return 0; }
  mkdir -p "$QD" || die "can't create $QD"
  printf 'owner %s\nsince %s\n' "$*" "$(date -u +%Y-%m-%dT%H:%MZ)" >"$LOCK"
  echo "lock: $* is testing. Agents can't rebuild, switch, reset or stash the main checkout until release."
}

cmd_release() {
  [ -f "$LOCK" ] || { echo "lock: already free"; return 0; }
  echo "lock released (was $(sed -n 's/^owner //p' "$LOCK"))"
  rm -f "$LOCK"
}

main() {
  local c="${1:-}"
  case "$c" in '') usage 2 ;; -h | --help | help) usage 0 ;; esac
  shift
  setup_repo
  case "$c" in
    init) cmd_init "$@" ;;
    add) cmd_add "${1:-}" ;;
    remove) cmd_remove "${1:-}" "${2:-}" ;;
    rebuild) cmd_rebuild "${1:-}" ;;
    status) cmd_status ;;
    check-pr) cmd_check_pr "${1:-}" ;;
    checklist) cmd_checklist ;;
    owner) cmd_owner "$@" ;;
    release) cmd_release ;;
    *) usage 2 ;;
  esac
}

main "$@"
