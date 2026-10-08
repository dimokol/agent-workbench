#!/usr/bin/env bash
# Tests for install.sh. It installs from this clone into temp folders, so nothing
# is downloaded and no real settings or skills are touched. Run: bash tests/install-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
nok() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      | /'; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) nok "$1" "$2" ;; esac; }
inst() { SKILLS_DIR="$T/skills" PARTS_DIR="$T/parts" bash "$ROOT/install.sh" "$@" 2>&1; }

out=$(inst worktree-hygiene)
[ -f "$T/skills/worktree-hygiene/SKILL.md" ] && ok "a skill lands in the skills folder" || nok "a skill lands in the skills folder" "$out"
has "a re-run skips a skill that exists" "$(inst worktree-hygiene)" "exists, skipped"

out=$(inst --force worktree-hygiene)
is_only=$(ls "$T/skills")
[ "$is_only" = worktree-hygiene ] && ok "--force leaves one copy in the skills folder" || nok "--force leaves one copy in the skills folder" "$is_only"
backup=$(ls -d "$T/skills-backup"/worktree-hygiene.* 2>/dev/null | head -n 1)
[ -f "$backup/SKILL.md" ] && ok "--force keeps the old copy next to the skills folder" || nok "--force keeps the old copy next to the skills folder" "$out"
has "--force says where the old copy went" "$out" "$T/skills-backup/worktree-hygiene."
out=$(inst --force worktree-hygiene)
[ "$(ls "$T/skills-backup" | wc -l | tr -d ' ')" = 2 ] && ok "a second --force in the same second keeps both old copies" ||
  nok "a second --force in the same second keeps both old copies" "$(ls -R "$T/skills-backup")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
