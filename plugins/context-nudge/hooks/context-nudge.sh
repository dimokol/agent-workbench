#!/bin/sh
# Runs context_nudge.py. Without python3 it allows the prompt and says so once per session.
if ! command -v python3 >/dev/null 2>&1; then
  marker="${TMPDIR:-/tmp}/context-nudge-nopython-$PPID"
  if [ ! -e "$marker" ]; then
    : > "$marker" 2>/dev/null
    printf '%s\n' '{"systemMessage":"context-nudge: python3 is not installed, so context size nudges are off."}'
  fi
  exit 0
fi
case $0 in */*) dir=${0%/*} ;; *) dir=. ;; esac
exec python3 "$dir/context_nudge.py"
