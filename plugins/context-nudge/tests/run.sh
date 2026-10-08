#!/bin/sh
# Runs the context-nudge tests. Needs python3.
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 -m unittest discover -s "$HERE" -p 'test_*.py' -v
