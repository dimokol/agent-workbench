#!/usr/bin/env zsh
# storage-reclaim: read-only survey. Deletes nothing, ever.
# Prints free space, memory-held disk, the biggest directories, the known
# high-yield candidates, and the processes that make deleting unsafe right now.
#
# Optional settings (plugin option first, then plain env var, then default):
#   lock_dir         CLAUDE_PLUGIN_OPTION_LOCK_DIR         / STORAGE_RECLAIM_LOCK_DIR
#   worktree_suffix  CLAUDE_PLUGIN_OPTION_WORKTREE_SUFFIX  / STORAGE_RECLAIM_WORKTREE_SUFFIX
# Both default to empty, which skips that check.

emulate -L zsh
setopt null_glob

LOCK_DIR=${CLAUDE_PLUGIN_OPTION_LOCK_DIR:-${STORAGE_RECLAIM_LOCK_DIR:-}}
WT_SUFFIX=${CLAUDE_PLUGIN_OPTION_WORKTREE_SUFFIX:-${STORAGE_RECLAIM_WORKTREE_SUFFIX:-}}
OS=$(uname -s 2>/dev/null)

# Project roots to search. Searches are depth-limited so a huge tree can't hang the scan.
ROOTS=()
for r in "$HOME/Documents" "$HOME/Projects" "$HOME/code"; do
  [[ -d "$r" ]] && ROOTS+=("$r")
done

h()    { printf '\n=== %s ===\n' "$1"; }
size() { du -xsh "$1" 2>/dev/null | cut -f1; }
has()  { [[ -e "$1" ]]; }

h "FREE SPACE (on macOS the Data volume is the one that fills up)"
df -h / /System/Volumes/Data 2>/dev/null | grep -v "^map"

if [[ "$OS" == Darwin ]]; then
  h "DISK HELD BY MEMORY PRESSURE (returns when apps close, not by deleting)"
  df -h /System/Volumes/VM 2>/dev/null | tail -1
  sysctl -n vm.swapusage 2>/dev/null
fi

h "BIGGEST DIRECTORIES IN HOME"
du -xsh "$HOME"/* "$HOME"/.[a-z]* 2>/dev/null | sort -rh | head -12

h "SAFETY GATE: processes that make deletion unsafe right now"
ps -eo pid,command 2>/dev/null \
  | grep -iE "jest|vitest|next dev|next-server|node --watch|webpack|vite|rollup|esbuild|tsc |npm |pnpm |yarn |gradle|xcodebuild|docker" \
  | grep -v grep | cut -c1-140
print -r -- "(anything above pins its project's node_modules and build output, so leave those alone)"

h "SAFETY GATE: locks and worktrees held by other sessions"
if [[ -n "$LOCK_DIR" && ${#ROOTS} -gt 0 ]]; then
  find "${ROOTS[@]}" -maxdepth 5 -name "$LOCK_DIR" -type d -prune 2>/dev/null \
    | while read -r d; do
        for lock in "$d"/*(N); do print -r -- "LOCK HELD: $lock"; done
      done
else
  print -r -- "(no lock_dir configured)"
fi
if [[ -n "$WT_SUFFIX" && ${#ROOTS} -gt 0 ]]; then
  find "${ROOTS[@]}" -maxdepth 4 -name "*$WT_SUFFIX" -type d -prune 2>/dev/null \
    | while read -r wt; do print -r -- "worktree folder in use: $wt"; done
else
  print -r -- "(no worktree_suffix configured)"
fi
if command -v git >/dev/null 2>&1; then
  print -r -- "(run 'git worktree list' in your active repos too: linked worktrees may sit anywhere)"
fi

h "SUPERSEDED TOOL VERSIONS (keep only the running one)"
for base in "$HOME/.vscode/extensions" "$HOME/.cursor/extensions"; do
  has "$base" || continue
  print -r -- "$base:"
  du -xsh "$base"/*/ 2>/dev/null | sort -rh | head -6
done
has "$HOME/.local/share/claude/versions" && {
  print -r -- "claude CLI versions (current: $(claude --version 2>/dev/null | head -1)):"
  du -xsh "$HOME"/.local/share/claude/versions/* 2>/dev/null | sort -rh
}

h "CACHES (rebuild themselves)"
du -xsh "$HOME"/Library/Caches/* 2>/dev/null | sort -rh | head -8
for c in "$HOME/.npm/_cacache" "$HOME/Library/Caches/pip" "$HOME/Library/Caches/Homebrew" "$HOME/.cache"; do
  has "$c" && printf "%s\t%s\n" "$(size $c)" "$c"
done

h "SDKs, SIMULATORS, VM IMAGES (biggest wins, always a re-download)"
xcrun simctl runtime list 2>/dev/null | tail -3
has "$HOME/Library/Developer/CoreSimulator/Devices" && \
  printf "%s\tsimulator devices (%s of them)\n" \
    "$(size "$HOME/Library/Developer/CoreSimulator/Devices")" \
    "$(ls "$HOME/Library/Developer/CoreSimulator/Devices" 2>/dev/null | wc -l | tr -d ' ')"
for v in "$HOME/Library/Application Support/Claude/vm_bundles" "$HOME/Library/Containers/com.docker.docker" "$HOME/Library/Android" "$HOME/.gradle" "$HOME/Library/Developer/Xcode/DerivedData"; do
  has "$v" && printf "%s\t%s\n" "$(size $v)" "$v"
done

h "DEPENDENCY FOLDERS AND BUILD OUTPUT IN PROJECTS"
if [[ ${#ROOTS} -gt 0 ]]; then
  find "${ROOTS[@]}" -maxdepth 5 -name node_modules -type d -prune 2>/dev/null \
    | while read -r nm; do printf "%s\t%s\n" "$(size $nm)" "$nm"; done | sort -rh | head -12
  find "${ROOTS[@]}" -maxdepth 4 \( -name .next -o -name dist -o -name .turbo -o -name target \) -type d -prune 2>/dev/null \
    | while read -r b; do printf "%s\t%s\n" "$(size $b)" "$b"; done | sort -rh | head -8
else
  print -r -- "(no ~/Documents, ~/Projects or ~/code found)"
fi

h "NEEDS A LOOK BEFORE DELETING (may be the only copy)"
SCAN_DIRS=()
for r in "$HOME/Downloads" "$HOME/Documents"; do
  [[ -d "$r" ]] && SCAN_DIRS+=("$r")
done
if [[ ${#SCAN_DIRS} -gt 0 ]]; then
  find "${SCAN_DIRS[@]}" -maxdepth 4 -type f \( -name "*.zip" -o -name "*.dmg" -o -name "*.pkg" -o -name "*.iso" \) -size +100M 2>/dev/null \
    | while read -r f; do printf "%s\t%s\n" "$(du -h "$f" 2>/dev/null | cut -f1)" "$f"; done | sort -rh | head -10
fi
print -r -- "(zip: confirm it is really extracted, since expired transfer links make these the last copy)"
print -r -- "(dmg/pkg: confirm the app is in /Applications before removing the installer)"

printf "\nSurvey only. Nothing was deleted. Propose in tiers, get approval, then delete.\n"
