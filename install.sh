#!/usr/bin/env bash
# Install parts of dimokol/agent-workbench without the Claude Code plugin system: for Codex, other agents,
# or people who wire hooks by hand. With Claude Code plugins, use
# `claude plugin install <part>@dimokol` instead.
#
#   install.sh --list               list the parts
#   install.sh <part> [<part>...]   install parts
#   install.sh --force <part>       replace a skill folder that already exists (old one is kept as .bak)
#
# Skills are copied into $SKILLS_DIR (default ~/.claude/skills; for Codex use ~/.codex/skills).
# Hook and MCP parts are copied into $PARTS_DIR (default ~/.claude/parts/<part>) and the script
# prints the settings snippet to paste. It never edits your settings files.
set -euo pipefail

REPO="dimokol/agent-workbench"
REF="${REPO_REF:-main}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
PARTS_DIR="${PARTS_DIR:-$HOME/.claude/parts}"
FORCE=0

# Use the clone this script sits in, if any. Piped through curl, BASH_SOURCE is empty, so the
# current directory is never mistaken for the repo.
here="$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent/x}")" 2>/dev/null && pwd || true)"
if [ -n "${SOURCE_DIR:-}" ]; then
  src="$SOURCE_DIR"
elif [ -n "$here" ] && [ -f "$here/.claude-plugin/marketplace.json" ] && [ -d "$here/plugins" ]; then
  src="$here"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$tmp" --strip-components=1
  src="$tmp"
fi

desc() { sed -n 's/^ *"description": *"\(.*\)",\{0,1\}$/\1/p' "$1/.claude-plugin/plugin.json" | head -n 1; }

list() {
  for d in "$src"/plugins/*/; do
    p="$(basename "$d")"
    printf '%-24s %s\n' "$p" "$(desc "$d")"
  done
}

install_part() {
  part="$1"; d="$src/plugins/$part"
  [ -d "$d" ] || { echo "No part named '$part'. Run with --list." >&2; return 1; }
  if [ "$part" = "starter" ]; then
    for p in git-guardrails machine-pressure worktree-hygiene agent-chat; do install_part "$p"; done
    return 0
  fi
  echo "== $part"
  if [ -d "$d/skills" ]; then
    mkdir -p "$SKILLS_DIR"
    for s in "$d"/skills/*/; do
      name="$(basename "$s")"; dest="$SKILLS_DIR/$name"
      if [ -e "$dest" ] && [ "$FORCE" -ne 1 ]; then
        echo "  skill $name: $dest exists, skipped (use --force to replace it)"
        continue
      fi
      [ -e "$dest" ] && mv "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)"
      cp -R "$s" "$dest"
      echo "  skill $name -> $dest"
    done
  fi
  if [ -f "$d/hooks/hooks.json" ] || [ -f "$d/.mcp.json" ]; then
    dest="$PARTS_DIR/$part"
    mkdir -p "$PARTS_DIR"
    rm -rf "$dest.new"; cp -R "$d" "$dest.new"
    [ -e "$dest" ] && mv "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dest.new" "$dest"
    echo "  files -> $dest"
  fi
  if [ -f "$d/hooks/hooks.json" ]; then
    echo "  Hooks (Claude Code only). Merge these events into the \"hooks\" object of ~/.claude/settings.json:"
    if command -v jq >/dev/null 2>&1; then
      jq --arg root "$dest" '.hooks | walk(if type == "string" then gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $root) else . end)' \
        "$dest/hooks/hooks.json" | sed 's/^/    /'
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["hooks"], indent=2).replace("${CLAUDE_PLUGIN_ROOT}", sys.argv[2]))' \
        "$dest/hooks/hooks.json" "$dest" | sed 's/^/    /'
    else
      echo "    (no jq or python3: copy the \"hooks\" object from $dest/hooks/hooks.json and replace \${CLAUDE_PLUGIN_ROOT} with $dest)"
    fi
    echo "  Settings: see $dest/README.md."
  fi
  if [ -f "$d/.mcp.json" ]; then
    # agent-chat is the only MCP part; its server lives at server/server.mjs.
    echo "  MCP server. Claude Code: claude mcp add $part --scope user -- node $dest/server/server.mjs"
    echo "  Codex and other clients: see $dest/README.md."
  fi
  echo "  Restart your agent to pick it up."
}

[ $# -eq 0 ] && { echo "Usage: install.sh --list | install.sh [--force] <part>..."; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --list) list ;;
    --force) FORCE=1 ;;
    -*) echo "Unknown option $arg" >&2; exit 1 ;;
    *) install_part "$arg" ;;
  esac
done
