#!/bin/sh
# The real plugins/machine-pressure/scripts/pressure.sh, reading the stub system
# tools in fixtures/red-machine instead of this machine's. demo.sh also points the
# gate at this file (PRESSURE_PROBE, the gate's own test hook), so the statusline
# and the gate see the same fixture.
here=$(cd "$(dirname "$0")/.." && pwd)
PATH="$here/fixtures/red-machine:$PATH" exec sh "$DEMO_PLUGINS/machine-pressure/scripts/pressure.sh" "$@"
