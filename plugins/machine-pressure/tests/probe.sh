#!/bin/sh
# Probe tests: pressure.sh against stubbed sysctl, vm_stat, ps, df, uname and a
# fake /proc root. Every case runs in its own temp dir, deleted at the end.
HERE=$(cd "$(dirname "$0")" && pwd)
PROBE=$HERE/../scripts/pressure.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok() { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1 (got: $2)"; }
eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 want=$2" "$3"; fi
}

# New sandbox: $BIN with stubs on PATH, $TMPDIR private, defaults for a healthy 8-core 16 GB Mac.
mkenv() {
  rm -rf "$WORK/env"; mkdir -p "$WORK/env/bin" "$WORK/env/tmp" "$WORK/env/proc"
  BIN=$WORK/env/bin
  OSNAME=Darwin; LOAD="2.40"; MEMSIZE=17179869184; SWAPLINE="total = 2048.00M  used = 1024.00M  free = 1024.00M  (encrypted)"
  FREEPAGES=100000; INACTIVE=300000; SPEC=24288; PURGE=100000   # 524288 pages = 8192 MB available
  PSCPU="40 30 10 0"; DISKKB=104857600; NCPU=8; MEMLEVEL=1
  write_stubs
}

write_stubs() {
  printf '#!/bin/sh\necho %s\n' "$OSNAME" > "$BIN/uname"
  cat > "$BIN/sysctl" <<EOF
#!/bin/sh
case "\$2" in
  hw.ncpu) echo $NCPU ;;
  vm.loadavg) echo "{ $LOAD 1.00 1.00 }" ;;
  hw.memsize) echo $MEMSIZE ;;
  vm.swapusage) echo "$SWAPLINE" ;;
  kern.memorystatus_vm_pressure_level) [ -n "$MEMLEVEL" ] && echo $MEMLEVEL || exit 1 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$BIN/vm_stat" <<EOF
#!/bin/sh
cat <<OUT
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               $FREEPAGES.
Pages active:                             200000.
Pages inactive:                           $INACTIVE.
Pages speculative:                        $SPEC.
Pages purgeable:                          $PURGE.
OUT
EOF
  cat > "$BIN/ps" <<EOF
#!/bin/sh
for v in $PSCPU; do echo "  \$v"; done
EOF
  cat > "$BIN/df" <<EOF
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
case "\$*" in
  *" /") echo "/dev/disk1 100000000 47571200 52428800 48% /" ;;
  *) echo "/dev/disk2 500000000 400000000 $DISKKB 80% /home" ;;
esac
EOF
  chmod +x "$BIN"/*
}

probe() { # args...  (uses the sandbox)
  PATH="$BIN:$PATH" TMPDIR="$WORK/env/tmp" PRESSURE_PROC_ROOT="$WORK/env/proc" NO_COLOR="${PCOLOR-1}" sh "$PROBE" "$@"
}
jf() { printf '%s' "$1" | jq -r "$2"; }

echo "== macOS: healthy machine =="
mkenv
out=$(probe --json)
eq "level OK" OK "$(jf "$out" .level)"
eq "cpu 80/8 cores = 10" 10 "$(jf "$out" .cpu_pct)"
eq "ram 50%" 50 "$(jf "$out" .ram_pct)"
eq "swap 50%" 50 "$(jf "$out" .swap_pct)"
eq "load" 2.40 "$(jf "$out" .load1)"
eq "cores" 8 "$(jf "$out" .cores)"
eq "disk 100 GB, read on the current folder's disk, not /" 100.0 "$(jf "$out" .disk_free_gb)"
eq "memory pressure normal" normal "$(jf "$out" .mem_pressure)"
eq "human line" "OK | CPU 10% | RAM 50% | swap 50% | load 2.4 | disk 100G | clear" "$(probe)"
eq "statusline" "CPU 10% | RAM 50% | swap 50% | load 2.4 | disk 100G | pressure OK" "$(probe --statusline)"
eq "field cpu" "CPU 10%" "$(probe --field cpu)"
eq "field ram" "RAM 50%" "$(probe --field ram)"
eq "field swap" "swap 50%" "$(probe --field swap)"
eq "field load" "load 2.4" "$(probe --field load)"
eq "field disk" "disk 100G" "$(probe --field disk)"
eq "field level" "pressure OK" "$(probe --field level)"
probe --field bogus >/dev/null 2>&1; eq "bad field exits 2" 2 $?
c=$(PCOLOR= probe --field level); eq "green when OK" "$(printf '\033[32mpressure OK\033[0m')" "$c"

echo "== macOS: thresholds =="
mkenv; FREEPAGES=2000; INACTIVE=20000; SPEC=5000; PURGE=5768; write_stubs   # 32768 pages = 512 MB
out=$(probe --json); eq "ram 96% is RED" RED "$(jf "$out" .level)"
eq "RED color" "$(printf '\033[31mRAM 96%%\033[0m')" "$(PCOLOR= probe --field ram)"
mkenv; DISKKB=15728640; write_stubs
eq "15 GB free is AMBER" AMBER "$(jf "$(probe --json)" .level)"
mkenv; DISKKB=5242880; write_stubs
eq "5 GB free is RED" RED "$(jf "$(probe --json)" .level)"
mkenv; LOAD="13.0"; write_stubs
eq "load 13 on 8 cores is AMBER (1.5x = 12)" AMBER "$(jf "$(probe --json)" .level)"
mkenv; LOAD="25.0"; write_stubs
eq "load 25 on 8 cores is RED (3x = 24)" RED "$(jf "$(probe --json)" .level)"
mkenv; SWAPLINE="total = 2048.00M  used = 1900.00M  free = 148.00M  (encrypted)"; write_stubs
out=$(probe --json)
eq "macOS: swap 92% is shown" 92 "$(jf "$out" .swap_pct)"
eq "macOS: swap 92% does not set the level" OK "$(jf "$out" .level)"
eq "macOS: the swap widget has no level color" "swap 92%" "$(PCOLOR= probe --field swap)"
mkenv; MEMLEVEL=2; write_stubs
out=$(probe --json)
eq "macOS: kernel memory pressure warn is AMBER" AMBER "$(jf "$out" .level)"
eq "macOS: mem_pressure warn" warn "$(jf "$out" .mem_pressure)"
eq "macOS: the RAM widget shows it" "$(printf '\033[33mRAM 50%%\033[0m')" "$(PCOLOR= probe --field ram)"
mkenv; MEMLEVEL=4; write_stubs
out=$(probe --json)
eq "macOS: kernel memory pressure critical is RED" RED "$(jf "$out" .level)"
eq "macOS: mem_pressure critical" critical "$(jf "$out" .mem_pressure)"
mkenv; MEMLEVEL=; write_stubs
out=$(probe --json)
eq "macOS: no kernel level read: null" null "$(jf "$out" .mem_pressure)"
eq "macOS: no kernel level read: other signals count" OK "$(jf "$out" .level)"
mkenv; SWAPLINE="total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)"; write_stubs
eq "no swap configured is 0%" 0 "$(jf "$(probe --json)" .swap_pct)"
mkenv; PSCPU="400 400 0"; write_stubs
eq "cpu 800/8 capped at 100 is RED" RED "$(jf "$(probe --json)" .level)"

echo "== config: plugin option, then env var, then default =="
mkenv
eq "plugin option lowers ram_amber" AMBER "$(jf "$(CLAUDE_PLUGIN_OPTION_RAM_AMBER=40 probe --json)" .level)"
mkenv
eq "env var fallback" AMBER "$(jf "$(MACHINE_PRESSURE_RAM_AMBER=40 probe --json)" .level)"
mkenv
eq "plugin option wins over env var" OK "$(jf "$(CLAUDE_PLUGIN_OPTION_RAM_AMBER=90 MACHINE_PRESSURE_RAM_AMBER=40 probe --json)" .level)"
mkenv
eq "junk value falls back to default" OK "$(jf "$(CLAUDE_PLUGIN_OPTION_RAM_AMBER=abc probe --json)" .level)"
mkenv; LOAD="5.0"; write_stubs
eq "load_amber_x 0.5 (4.0) triggers AMBER" AMBER "$(jf "$(CLAUDE_PLUGIN_OPTION_LOAD_AMBER_X=0.5 probe --json)" .level)"
mkenv; DISKKB=15728640; write_stubs
eq "disk_amber_gb 10 clears AMBER" OK "$(jf "$(CLAUDE_PLUGIN_OPTION_DISK_AMBER_GB=10 probe --json)" .level)"

echo "== failed reads never produce RED =="
mkenv
printf '#!/bin/sh\nexit 1\n' > "$BIN/sysctl"; printf '#!/bin/sh\nexit 1\n' > "$BIN/vm_stat"
printf '#!/bin/sh\nexit 1\n' > "$BIN/ps"; printf '#!/bin/sh\nexit 1\n' > "$BIN/df"
out=$(probe --json)
eq "all reads fail: UNKNOWN" UNKNOWN "$(jf "$out" .level)"
eq "all reads fail: null cpu" null "$(jf "$out" .cpu_pct)"
eq "UNKNOWN statusline" "CPU n/a | RAM n/a | swap n/a | load n/a | disk n/a | pressure UNKNOWN" "$(probe --statusline)"
mkenv; printf '#!/bin/sh\nexit 1\n' > "$BIN/vm_stat"
out=$(probe --json)
eq "vm_stat fails: ram null" null "$(jf "$out" .ram_pct)"
eq "vm_stat fails: other signals still count" OK "$(jf "$out" .level)"
mkenv; OSNAME=FreeBSD; write_stubs
eq "unsupported OS: UNKNOWN" UNKNOWN "$(jf "$(probe --json)" .level)"
mkenv; printf '#!/bin/sh\necho Darwin garbage\n' > "$BIN/sysctl"
eq "garbage sysctl output is ignored" null "$(jf "$(probe --json)" .load1)"

echo "== Linux: fake /proc =="
linux_proc() { # idle-total pair is written by caller; here meminfo, loadavg and cpu lines
  cat > "$WORK/env/proc/meminfo" <<EOF
MemTotal:        8000000 kB
MemFree:          500000 kB
MemAvailable:    4000000 kB
SwapTotal:       $1 kB
SwapFree:        $2 kB
EOF
  echo "0.50 0.60 0.70 1/200 1234" > "$WORK/env/proc/loadavg"
}
write_stat() { # user system idle
  printf 'cpu  %s 0 %s %s 0 0 0 0 0 0\ncpu0 1 0 1 1 0 0 0 0 0 0\ncpu1 1 0 1 1 0 0 0 0 0 0\ncpu2 1 0 1 1 0 0 0 0 0 0\ncpu3 1 0 1 1 0 0 0 0 0 0\n' "$1" "$2" "$3" > "$WORK/env/proc/stat"
}
mkenv; OSNAME=Linux; write_stubs; rm -f "$BIN/sysctl" "$BIN/vm_stat"
linux_proc 2000000 1500000
write_stat 1000 1000 8000
# sleep stub: advances the counters so the second reading differs from the first
cat > "$BIN/sleep" <<EOF
#!/bin/sh
printf 'cpu  1500 0 1500 8500 0 0 0 0 0 0\ncpu0 1 0 1 1 0 0 0 0 0 0\ncpu1 1 0 1 1 0 0 0 0 0 0\ncpu2 1 0 1 1 0 0 0 0 0 0\ncpu3 1 0 1 1 0 0 0 0 0 0\n' > "$WORK/env/proc/stat"
: > "$WORK/env/slept"
EOF
chmod +x "$BIN/sleep"
out=$(probe --json)
eq "linux level OK" OK "$(jf "$out" .level)"
eq "linux cpu from two readings = 66" 66 "$(jf "$out" .cpu_pct)"
eq "linux ram 50%" 50 "$(jf "$out" .ram_pct)"
eq "linux swap 25%" 25 "$(jf "$out" .swap_pct)"
eq "linux load" 0.50 "$(jf "$out" .load1)"
eq "linux cores from cpuN lines" 4 "$(jf "$out" .cores)"
eq "linux disk" 100.0 "$(jf "$out" .disk_free_gb)"

# second run: previous reading is 10 s old, so no sleep is needed
rm -f "$WORK/env/slept"
now=$(date +%s)
printf '8000 10000 %s\n' "$((now - 10))" > "$WORK/env/tmp/machine-pressure-$(id -u).cpu"
rm -f "$WORK/env/tmp/"machine-pressure-*.cache
write_stat 1500 1500 8500
out=$(probe --json)
eq "linux cpu from saved reading = 66" 66 "$(jf "$out" .cpu_pct)"
[ -e "$WORK/env/slept" ] && bad "no sleep when a recent reading exists" slept || ok "no sleep when a recent reading exists"

eq "linux has no kernel memory level" null "$(jf "$out" .mem_pressure)"
linux_proc 2000000 160000
rm -f "$WORK/env/tmp/"machine-pressure-*.cache
eq "linux swap 92% is RED" RED "$(jf "$(probe --json)" .level)"
linux_proc 0 0
rm -f "$WORK/env/tmp/"machine-pressure-*.cache
eq "linux without swap is 0%" 0 "$(jf "$(probe --json)" .swap_pct)"
rm -f "$WORK/env/tmp/"machine-pressure-*.cache "$WORK/env/proc/meminfo"
out=$(probe --json)
eq "linux missing meminfo: ram null" null "$(jf "$out" .ram_pct)"
eq "linux missing meminfo: not RED" OK "$(jf "$out" .level)"
mkenv; OSNAME=Linux; write_stubs; rm -f "$BIN/sysctl" "$BIN/vm_stat"; printf '#!/bin/sh\nexit 1\n' > "$BIN/df"
rm -rf "$WORK/env/proc"
eq "linux with no /proc and no df is UNKNOWN, never RED" UNKNOWN "$(jf "$(probe --json)" .level)"

echo "== cache =="
mkenv
a=$(probe --json)
DISKKB=1048576; write_stubs
b=$(probe --json)
eq "second call inside 4 s reuses the sample" "$a" "$b"
c=$(PRESSURE_CACHE_TTL=0 probe --json)
eq "ttl 0 resamples (disk now 1 GB)" 1.0 "$(jf "$c" .disk_free_gb)"
eq "ttl 0 resample is RED on disk" RED "$(jf "$c" .level)"
mkenv
mkdir -p "$WORK/env/a" "$WORK/env/b"
a=$(cd "$WORK/env/a" && probe --json)
DISKKB=1048576; write_stubs
b=$(cd "$WORK/env/b" && probe --json)
eq "another folder inside 4 s reads its own disk" 1.0 "$(jf "$b" .disk_free_gb)"

echo
echo "probe: passed=$pass failed=$fail"
[ "$fail" = 0 ]
