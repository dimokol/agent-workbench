# Sourced by demo.tape inside VHS's bash, while the recording is hidden.
# It moves the shell into a throwaway sandbox (HOME, TMPDIR and the working folder
# all under one mktemp folder) so nothing on screen shows a real path, user or
# host, and defines the commands the tape types:
#   caption N     clears the screen and prints scene N's one-line caption
#   pretooluse    runs the plugins' real PreToolUse hooks on a Bash command
#   pressure.sh   the real machine-pressure probe, reading fixtures/red-machine
#   two-agents    scene 3: two agents talk through the real agent-chat server
# The plugins come from the checkout two folders up; set DEMO_PLUGINS to use another.

DEMO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export DEMO_PLUGINS=${DEMO_PLUGINS:-$(cd "$DEMO_DIR/../../plugins" && pwd)}
node_dir=$(dirname "$(command -v node)")

tmp_base=${TMPDIR:-/tmp}
DEMO_SANDBOX=$(mktemp -d "${tmp_base%/}/agent-workbench-demo.XXXXXX")
mkdir -p "$DEMO_SANDBOX/home" "$DEMO_SANDBOX/tmp" "$DEMO_SANDBOX/plugin-data" "$DEMO_SANDBOX/chat" "$DEMO_SANDBOX/shop"
trap 'rm -rf "$DEMO_SANDBOX"' EXIT

export HOME=$DEMO_SANDBOX/home
export TMPDIR=$DEMO_SANDBOX/tmp
export DEMO_PLUGIN_DATA=$DEMO_SANDBOX/plugin-data
export PATH="$DEMO_DIR/bin:$node_dir:/usr/bin:/bin:/usr/sbin:/sbin"
# The gate's test hook: run this probe instead of its own, so the gate and the
# statusline read the same fixture.
export PRESSURE_PROBE=$DEMO_DIR/bin/pressure.sh
export AGENT_CHAT_ROOT=$DEMO_SANDBOX/chat
export AGENT_CHAT_PROJECT=shop
unset PROMPT_COMMAND CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA GIT_GUARDRAILS_ALLOW PRESSURE_ALLOW
# Plugin settings from the recording machine would change what the hooks say.
for v in $(env | grep -Eo '^(CLAUDE_PLUGIN_OPTION_|GIT_GUARDRAILS_|MACHINE_PRESSURE_)[A-Z_]*'); do unset "$v"; done
cd "$DEMO_SANDBOX/shop" || return

# A blank line before every prompt keeps one command's output apart from the next.
PS1='\n\[\e[38;5;245m\]$\[\e[0m\] '

caption() {
  clear
  case $1 in
    1) text='git-guardrails: an agent tries to merge a PR and push to main' ;;
    2) text='machine-pressure: a machine out of RAM (fixture readings)' ;;
    3) text='agent-chat: two agents in two terminals agree on an API change' ;;
  esac
  printf '\e[1;38;5;117m# %s\e[0m\n' "$text"
}

pretooluse() { DEMO_COMMAND=$1 node "$DEMO_DIR/lib/pretooluse.mjs"; }
two-agents() { node "$DEMO_DIR/lib/two-agents.mjs"; }
