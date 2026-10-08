#!/usr/bin/env bash
# Runs scan.sh against a fake HOME and checks it prints its sections and deletes nothing.
set -u
here=$(cd "$(dirname "$0")" && pwd)
scan="$here/../skills/storage-reclaim/scripts/scan.sh"
fail=0
check() { if [ "$2" = ok ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

if ! command -v zsh >/dev/null 2>&1; then echo "zsh not installed, skipping"; exit 0; fi

fake=$(mktemp -d) || exit 1
trap 'rm -rf "$fake"' EXIT

mkdir -p "$fake/Documents/proj/node_modules/pkg" \
         "$fake/Documents/proj/.locks" \
         "$fake/Documents/proj-worktrees/feat" \
         "$fake/Downloads" "$fake/.npm/_cacache"
echo data > "$fake/Documents/proj/node_modules/pkg/index.js"
echo held > "$fake/Documents/proj/.locks/session-a"
echo cache > "$fake/.npm/_cacache/blob"
dd if=/dev/zero of="$fake/Downloads/big.zip" bs=1048576 count=101 2>/dev/null

snapshot() { (cd "$fake" && find . | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort); }
before=$(snapshot)

out=$(HOME="$fake" STORAGE_RECLAIM_LOCK_DIR=.locks STORAGE_RECLAIM_WORKTREE_SUFFIX=-worktrees zsh "$scan" 2>&1)
status=$?
after=$(snapshot)

[ "$status" -eq 0 ] && s=ok || s=bad; check "exits 0" $s
for sec in "FREE SPACE" "BIGGEST DIRECTORIES" "SAFETY GATE: processes" "SAFETY GATE: locks" \
           "CACHES" "DEPENDENCY FOLDERS" "NEEDS A LOOK"; do
  case "$out" in *"=== $sec"*) s=ok;; *) s=bad;; esac; check "prints section: $sec" $s
done
case "$out" in *"LOCK HELD: $fake/Documents/proj/.locks/session-a"*) s=ok;; *) s=bad;; esac
check "lists the configured lock" $s
case "$out" in *"worktree folder in use: $fake/Documents/proj-worktrees"*) s=ok;; *) s=bad;; esac
check "lists the configured worktree folder" $s
case "$out" in *"$fake/Documents/proj/node_modules"*) s=ok;; *) s=bad;; esac
check "lists node_modules" $s
case "$out" in *"$fake/Downloads/big.zip"*) s=ok;; *) s=bad;; esac
check "flags the large archive" $s
case "$out" in *"Nothing was deleted"*) s=ok;; *) s=bad;; esac
check "prints the survey-only footer" $s
[ "$before" = "$after" ] && s=ok || s=bad; check "fake HOME is unchanged (nothing deleted or written)" $s

out2=$(HOME="$fake" zsh "$scan" 2>&1)
case "$out2" in *"no lock_dir configured"*) s=ok;; *) s=bad;; esac
check "unset lock_dir is skipped with a note" $s

[ "$fail" -eq 0 ] && echo "all passed" || echo "failures"
exit "$fail"
