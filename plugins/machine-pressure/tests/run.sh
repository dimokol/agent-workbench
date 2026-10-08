#!/bin/sh
# Runs every test file. Needs sh, awk and jq.
HERE=$(cd "$(dirname "$0")" && pwd)
status=0
for t in classifier probe gate; do
  echo "##### $t"
  sh "$HERE/$t.sh" || status=1
  echo
done
if [ "$status" = 0 ]; then echo "all machine-pressure tests passed"; else echo "SOME TESTS FAILED"; fi
exit "$status"
