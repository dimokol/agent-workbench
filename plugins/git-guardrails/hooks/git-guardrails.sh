#!/bin/sh
# Launcher for git-guardrails.mjs. If Node is missing or can't run the hook, the
# command is allowed and the user hears about it once per session.
input=$(cat)
if command -v node >/dev/null 2>&1; then
  printf '%s' "$input" | node "${0%/*}/git-guardrails.mjs" 2>/dev/null && exit 0
  why='node failed to run the hook'
else
  why='node is not on PATH'
fi
session=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.-]*\)".*/\1/p')
state=${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}
mark="$state/git-guardrails-no-node-${session:-unknown}"
[ -e "$mark" ] && exit 0
mkdir -p "$state" 2>/dev/null
: > "$mark" 2>/dev/null
printf '{"systemMessage":"git-guardrails is off for this session: %s, so git commands run unchecked. Install Node 18 or newer to turn it on."}\n' "$why"
exit 0
