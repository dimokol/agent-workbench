#!/usr/bin/env bash
# qa-branch-guard.sh: PreToolUse hook (Bash). In a repo set up with `qa-branch.sh
# init`, denies pushing the integration branch or its -prev copy, force-pushing a
# queued PR branch, and (while the lock exists) switching, `reset --hard` or `stash`
# in the main checkout. QA_BRANCH_ALLOW=1 before a command passes all but the first.

set -f
input=$(cat)

if ! command -v jq >/dev/null 2>&1; then # allow, and say so once per session
  sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  mark="${TMPDIR:-/tmp}/qa-branch-guard-nojq-${sid:-unknown}"
  [ -e "$mark" ] || { : >"$mark"; printf '%s\n' '{"systemMessage":"integration-branch-qa: jq is not installed, so the QA branch guard lets every command through. Install jq to turn it on."}'; }
  exit 0
fi
command -v git >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
case "$cmd" in *git*) ;; *) exit 0 ;; esac
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""'); [ -n "$cwd" ] || cwd=$PWD

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

absdir() { # absdir <from> <path>
  local p; case "$2" in /*) p=$2 ;; "~" | "~/"*) p="$HOME${2#\~}" ;; *) p="$1/$2" ;; esac
  (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
}

# Same lookup as qa-branch.sh: env var, then .qa/config, then the default.
setting() {
  local v
  eval "v=\${INTEGRATION_BRANCH_QA_$(printf '%s' "$1" | tr a-z A-Z):-}"
  [ -n "$v" ] || v=$(sed -n "s/^$1=//p" "$MAIN/.qa/config" 2>/dev/null | tail -n 1)
  printf '%s' "${v:-$2}"
}

# Facts about the repo at $1. Fails unless `qa-branch.sh init` ran there.
repo_ctx() {
  local qd
  TOP=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  MAIN=$(git -C "$1" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -f "$MAIN/.qa/config" ] || return 1
  INT=$(setting integration_branch qa-integration) qd=$(setting qa_dir .qa)
  case "$qd" in /*) ;; *) qd="$MAIN/$qd" ;; esac
  TOP=$(absdir / "$TOP") MAIN=$(absdir / "$MAIN") CUR=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null) LOCKED=""
  if [ -f "$qd/lock" ]; then LOCKED=$(sed -n 's/^owner //p' "$qd/lock" | head -n 1); LOCKED=${LOCKED:-someone}; fi
  QUEUED=$(awk '/^```qa-queue/ { on = 1; next } on && /^```/ { on = 0 }
    on && NF >= 2 { sub(/^#/, "", $1); print $1, $2 }' "$qd/queue.md" 2>/dev/null)
}

# One side of a refspec as a branch name, minus ~N and ^ suffixes. HEAD, @ and
# a side that is one whole expansion ($(...) splits to "$", or $VAR, ${VAR})
# count as the current branch; "v$VERSION" stays as it is.
ref_name() {
  local s=${1%%[~^]*}
  case "$s" in '$'*) printf '%s' "$s" | grep -Eq '^[$]([{]?[A-Za-z_][A-Za-z0-9_]*[}]?)?$' && s=HEAD ;; esac
  case "$s" in HEAD | @) s=${CUR:-HEAD} ;; esac
  printf '%s' "${s#refs/heads/}"
}

check_push() {
  local force="" all="" del="" remote="" specs="" r src dst plus n
  while [ $# -gt 0 ]; do
    case "$1" in
      --force | --force-with-lease | --force-with-lease=*) force=1 ;;
      --all | --mirror | --branches) all=1 ;;
      --delete) del=1 ;;
      -o | --push-option | --repo | --receive-pack | --exec) shift ;;
      --*) ;;
      -*) case "$1" in *f*) force=1 ;; esac; case "$1" in *d*) del=1 ;; esac ;;
      *) if [ -z "$remote" ]; then remote=$1; else specs="$specs $1"; fi ;;
    esac
    [ $# -gt 0 ] && shift
  done
  [ -n "$del" ] && return 0
  [ -n "$all" ] && git -C "$gdir" rev-parse --verify --quiet "refs/heads/$INT" >/dev/null && specs="$specs $INT"
  for r in ${specs:-HEAD}; do # a bare `git push [remote]` pushes the current branch
    plus=""; case "$r" in +*) plus=1 r=${r#+} ;; esac
    case "$r" in *:*) src=${r%%:*} dst=${r#*:} ;; *) src=$r dst=$r ;; esac
    src=$(ref_name "$src") dst=$(ref_name "$dst")
    [ -n "$src" ] || continue # ":branch" deletes a remote branch
    case " $src $dst " in *" $INT "* | *" $INT-prev "*)
      deny "Blocked: $INT is the local QA integration branch (and $INT-prev its last build). It never leaves this machine and is never merged. Commit the fix on its PR branch instead, in a worktree of that branch, push that, then rebuild with qa-branch.sh." ;;
    esac
    [ -n "$force$plus" ] && [ -z "$allow" ] || continue
    n=$(printf '%s\n' "$QUEUED" | awk -v b="$dst" '$2 == b { print $1; exit }')
    [ -n "$n" ] && deny "Blocked: force-push to $dst, the branch of PR #$n in the QA queue. The integration branch and other sessions build on its history, and a force-push can drop fixes carried back from testing. Push without force (merge $dst's base into it rather than rebasing). If the person testing says nothing will be lost, rerun the command starting with QA_BRANCH_ALLOW=1."
  done
}

check_main() {
  local sub=$1 name="" new="" a; shift
  [ -n "$allow" ] && return 0
  case "$sub" in
    checkout | switch)
      [ "$CUR" = "$INT" ] || return 0
      for a in "$@"; do
        case "$a" in
          --) [ "$sub" = checkout ] && return 0 ;; # paths follow: files only
          -b | -B | -c | -C | -d | --orphan | --detach | --create | --force-create) new=1 ;;
          -) name=- ;;
          -*) ;;
          *) [ -n "$name" ] || name=$a ;;
        esac
      done
      [ -z "$new" ] && { [ -z "$name" ] || [ "$name" = "$INT" ]; } && return 0
      # `git checkout <path>` restores a file. A name that is no commit here but a
      # branch on a remote is still a switch: git creates the local branch.
      [ "$sub$new" = checkout ] && [ "$name" != - ] &&
        ! git -C "$gdir" rev-parse --verify --quiet "$name^{commit}" >/dev/null &&
        [ -z "$(git -C "$gdir" for-each-ref --count=1 "refs/remotes/*/$name")" ] && return 0
      ;;
    reset) case " $* " in *" --hard "* | *" --keep "* | *" --merge "*) ;; *) return 0 ;; esac ;;
    stash) case "${1:-push}" in list | show) return 0 ;; esac ;;
  esac
  deny "Blocked: git $sub in the main checkout ($MAIN). $LOCKED is testing there (the QA lock), so its branch and files stay put while the dev servers run from it. Work in a worktree instead (git worktree add <path> <branch>). If the person testing asks for this, rerun it starting with QA_BRANCH_ALLOW=1."
}

# Split on shell separators (after joining line continuations) and check every
# git push / checkout / switch / reset / stash, following `cd` and `git -C`.
segs=$(printf '%s\n' "$cmd" |
  awk '{ if (sub(/\\$/, "")) { b = b $0 " "; next } print b $0; b = "" } END { if (b != "") print b }' |
  awk '{ gsub(/&&|\|\||[;|&()`]/, "\n"); print }' | tr -d "\"'")
dir=$cwd
while IFS= read -r seg; do
  set -- $seg
  allow=""
  while [ $# -gt 0 ]; do # skip assignments and wrappers (env, bash -c, eval, xargs ...)
    case "$1" in
      QA_BRANCH_ALLOW=1) allow=1 ;;
      [A-Za-z_]*=* | env | command | exec | nohup | time | sudo | bash | sh | zsh | eval | xargs | -*) ;;
      *) break ;;
    esac
    shift
  done
  [ $# -gt 0 ] || continue
  case "$1" in
    cd | pushd) dir=$(absdir "$dir" "${2:-$HOME}"); continue ;;
    git | */git) shift ;;
    *) continue ;;
  esac
  gdir=$dir
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) gdir=$(absdir "$gdir" "${2:-.}"); shift ;;
      -c | --git-dir | --work-tree | --namespace) shift ;;
      -*) ;;
      *) break ;;
    esac
    [ $# -gt 0 ] && shift
  done
  [ $# -gt 0 ] || continue
  sub=$1; shift
  case "$sub" in push | checkout | switch | reset | stash) ;; *) continue ;; esac
  repo_ctx "$gdir" || continue
  if [ "$sub" = push ]; then
    check_push "$@"
  elif [ -n "$LOCKED" ] && [ "$TOP" = "$MAIN" ]; then
    check_main "$sub" "$@"
  fi
done <<EOF
$segs
EOF
exit 0
