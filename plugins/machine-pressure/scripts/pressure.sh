#!/bin/sh
# pressure.sh: cheap machine-pressure probe (CPU, RAM, swap, load, free disk).
#
# Usage:
#   pressure.sh                 one human-readable line
#   pressure.sh --json          machine-readable (used by the heavy-op gate)
#   pressure.sh --statusline    one colored line for a Claude Code statusLine
#   pressure.sh --field NAME    one colored segment: cpu | ram | swap | load | disk | level
#
# Levels: OK, AMBER, RED, or UNKNOWN. The level is the worst of the signals that
# could be read. If no signal can be read (unsupported OS, failed reads) the
# level is UNKNOWN, never RED.
#
# Platforms: macOS (sysctl, vm_stat, ps, df) and Linux (/proc, df). Anything
# else reports UNKNOWN. On macOS the kernel's memory pressure level
# (kern.memorystatus_vm_pressure_level: warn is AMBER, critical is RED) counts
# with RAM, and swap is shown without setting the level: macOS grows swap on
# demand and keeps pages in it long after the pressure is gone.
#
# One sample per folder is cached for 4 seconds under $TMPDIR, so several
# statusline widgets rendered together share one reading.
#
# Thresholds are read from CLAUDE_PLUGIN_OPTION_<KEY> (set by the plugin), then
# MACHINE_PRESSURE_<KEY> (set by hand in settings.json "env"), then the default:
#   CPU_AMBER 85, CPU_RED 97         percent of all cores in use
#   RAM_AMBER 85, RAM_RED 93         percent of RAM in use (not available)
#   SWAP_AMBER 70, SWAP_RED 90       percent of swap in use (Linux only)
#   DISK_AMBER_GB 20, DISK_RED_GB 10 free GB on the current folder's disk (lower is worse;
#                                    on Linux a tmpfs folder falls back to $HOME's disk, then /)
#   LOAD_AMBER_X 1.5, LOAD_RED_X 3   1-minute load as a multiple of the core count
#
# Test hooks: PRESSURE_PROC_ROOT (fake /proc), PRESSURE_CACHE_TTL (seconds).

set -u

cfg() { # key default
  _u=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
  eval "_v=\${CLAUDE_PLUGIN_OPTION_$_u:-}"
  [ -n "$_v" ] || eval "_v=\${MACHINE_PRESSURE_$_u:-}"
  case $_v in ''|*[!0-9.]*|*.*.*|.) _v=$2 ;; esac
  printf '%s' "$_v"
}

OS=$(uname -s 2>/dev/null || echo unknown)
TMP=${TMPDIR:-/tmp}; TMP=${TMP%/}
UIDN=$(id -u 2>/dev/null || echo 0)
# Keyed by folder: free disk depends on where the probe runs.
DIRKEY=$(pwd -P 2>/dev/null | cksum 2>/dev/null); DIRKEY=${DIRKEY%% *}
CACHE="$TMP/machine-pressure-$UIDN-${DIRKEY:-0}.cache"
CPUSTATE="$TMP/machine-pressure-$UIDN.cpu"
TTL=${PRESSURE_CACHE_TTL:-4}
case $TTL in ''|*[!0-9]*) TTL=4 ;; esac

cpu=""; ram=""; swap=""; load1=""; disk=""; cores=""; mem=""

isnum() { case $1 in ''|*[!0-9.]*|*.*.*|.) return 1 ;; esac; return 0; }

# ---- samplers: each sets its variables, or leaves them empty on any failure ----

# Free disk where the probe runs. On Linux a folder on tmpfs (often /tmp) is RAM,
# not disk, so the disk of $HOME, else /, is measured instead.
sample_disk() {
  for _d in . "${HOME:-/}" /; do
    _r=$(df -P -k "$_d" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4, $NF}')
    [ -n "$_r" ] || continue
    if [ "$OS" = Linux ] && awk -v m="${_r#* }" '$2 == m { t = $3 } END { exit !(t ~ /^(tmpfs|ramfs|devtmpfs)$/) }' \
      "${PRESSURE_PROC_ROOT:-/proc}/mounts" 2>/dev/null; then
      continue
    fi
    disk=$(awk -v k="${_r%% *}" 'BEGIN{printf "%.1f", k/1048576}')
    return
  done
}

sample_darwin() {
  cores=$(sysctl -n hw.ncpu 2>/dev/null)
  case $cores in ''|*[!0-9]*|0) cores="" ;; esac

  load1=$(sysctl -n vm.loadavg 2>/dev/null | awk 'NF>=3 && $2 ~ /^[0-9.]+$/ {print $2; exit}')

  if [ -n "$cores" ]; then
    cpu=$(ps -A -o %cpu= 2>/dev/null | awk -v c="$cores" \
      'NF{s+=$1; n++} END{if(n==0)exit; v=s/c; if(v>100)v=100; printf "%d", v}')
  fi

  mem_total_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $1>0 {printf "%d", $1/1048576}')
  avail_mb=$(vm_stat 2>/dev/null | awk '
    /page size of/      { match($0,/[0-9]+/); pg=substr($0,RSTART,RLENGTH) }
    /Pages free/        { gsub(/\./,""); f=$3 }
    /Pages inactive/    { gsub(/\./,""); i=$3 }
    /Pages speculative/ { gsub(/\./,""); s=$3 }
    /Pages purgeable/   { gsub(/\./,""); p=$3 }
    END { if (pg=="" || f=="" || i=="") exit; printf "%d", (f+i+s+p)*pg/1048576 }')
  if [ -n "$mem_total_mb" ] && [ -n "$avail_mb" ]; then
    ram=$(awk -v a="$avail_mb" -v t="$mem_total_mb" 'BEGIN{v=(1-a/t)*100; if(v<0)v=0; printf "%d", v}')
  fi

  swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '
    { if (match($0,/total = [0-9.]+/)) t=substr($0,RSTART+8,RLENGTH-8)
      if (match($0,/used = [0-9.]+/))  u=substr($0,RSTART+7,RLENGTH-7) }
    END { if (t=="" || u=="") exit; printf "%d", (t+0<=0)?0:(u/t)*100 }')

  # 1 normal, 2 warn, 4 critical
  mem=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  case $mem in ''|*[!0-9]*|0) mem="" ;; esac
}

linux_cpu_counters() { # prints "idle total" from the aggregate cpu line
  awk '/^cpu /{ idle=$5+$6; t=0; for(i=2;i<=9;i++) t+=$i; print idle, t; exit }' "$1/stat" 2>/dev/null
}

sample_linux() {
  root=${PRESSURE_PROC_ROOT:-/proc}
  cores=$(grep -c '^cpu[0-9]' "$root/stat" 2>/dev/null)
  case $cores in ''|*[!0-9]*|0) cores=$(nproc 2>/dev/null) ;; esac
  case $cores in ''|*[!0-9]*|0) cores="" ;; esac

  load1=$(awk '$1 ~ /^[0-9.]+$/ {print $1; exit}' "$root/loadavg" 2>/dev/null)

  ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
    END { if (t+0<=0 || a=="") exit; v=(1-a/t)*100; if(v<0)v=0; printf "%d", v }' "$root/meminfo" 2>/dev/null)
  swap=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
    END { if (t=="" || f=="") exit; printf "%d", (t+0<=0)?0:(t-f)/t*100 }' "$root/meminfo" 2>/dev/null)

  # CPU: busy share between two readings of /proc/stat. Reuse the reading left by
  # the previous run when it is 1 to 60 seconds old, otherwise take two readings
  # 0.2 s apart.
  now=$(date +%s)
  cur=$(linux_cpu_counters "$root")
  [ -n "$cur" ] || return 0
  prev=""
  if [ -r "$CPUSTATE" ]; then
    read -r p_idle p_total p_ts < "$CPUSTATE" 2>/dev/null
    case "${p_idle:-x}${p_total:-x}${p_ts:-x}" in
      *[!0-9]*) ;;
      *) age=$((now - p_ts))
         if [ "$age" -ge 1 ] && [ "$age" -le 60 ]; then prev="$p_idle $p_total"; fi ;;
    esac
  fi
  if [ -z "$prev" ]; then
    prev=$cur
    sleep 0.2 2>/dev/null || sleep 1 2>/dev/null || return 0
    cur=$(linux_cpu_counters "$root")
    [ -n "$cur" ] || return 0
  fi
  cpu=$(awk -v p="$prev" -v c="$cur" 'BEGIN{
    split(p,a," "); split(c,b," "); dt=b[2]-a[2]; di=b[1]-a[1];
    if (dt<=0) exit; v=(1-di/dt)*100; if(v<0)v=0; if(v>100)v=100; printf "%d", v }')
  printf '%s %s\n' "$cur" "$now" > "$CPUSTATE.$$" 2>/dev/null && mv -f "$CPUSTATE.$$" "$CPUSTATE" 2>/dev/null
}

dash() { if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' '-'; fi; }
undash() { if [ "$1" = "-" ]; then printf ''; else printf '%s' "$1"; fi; }

load_cache() {
  [ -r "$CACHE" ] || return 1
  read -r c_ts c_cpu c_ram c_swap c_load c_disk c_cores c_mem < "$CACHE" 2>/dev/null || return 1
  case ${c_ts:-x} in *[!0-9]*) return 1 ;; esac
  [ -n "${c_mem:-}" ] || return 1
  age=$(( $(date +%s) - c_ts ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$TTL" ] || return 1
  cpu=$(undash "$c_cpu"); ram=$(undash "$c_ram"); swap=$(undash "$c_swap")
  load1=$(undash "$c_load"); disk=$(undash "$c_disk"); cores=$(undash "$c_cores"); mem=$(undash "$c_mem")
  return 0
}

store_cache() {
  printf '%s %s %s %s %s %s %s %s\n' "$(date +%s)" "$(dash "$cpu")" "$(dash "$ram")" "$(dash "$swap")" \
    "$(dash "$load1")" "$(dash "$disk")" "$(dash "$cores")" "$(dash "$mem")" > "$CACHE.$$" 2>/dev/null \
    && mv -f "$CACHE.$$" "$CACHE" 2>/dev/null
  rm -f "$CACHE.$$" 2>/dev/null
  return 0
}

if ! load_cache; then
  case $OS in
    Darwin) sample_darwin; sample_disk ;;
    Linux)  sample_linux;  sample_disk ;;
    *) ;;
  esac
  for _v in cpu ram swap load1 disk cores mem; do
    eval "isnum \"\$$_v\"" || eval "$_v="
  done
  store_cache
fi

# ---- levels: 0 OK, 1 AMBER, 2 RED, -1 unknown ----

CPU_AMBER=$(cfg cpu_amber 85);        CPU_RED=$(cfg cpu_red 97)
RAM_AMBER=$(cfg ram_amber 85);        RAM_RED=$(cfg ram_red 93)
SWAP_AMBER=$(cfg swap_amber 70);      SWAP_RED=$(cfg swap_red 90)
DISK_AMBER=$(cfg disk_amber_gb 20);   DISK_RED=$(cfg disk_red_gb 10)
LOAD_AMBER_X=$(cfg load_amber_x 1.5); LOAD_RED_X=$(cfg load_red_x 3)

lvl() { # value amber red, higher is worse
  [ -n "$1" ] || { echo -1; return; }
  awk -v v="$1" -v a="$2" -v r="$3" 'BEGIN{print (v+0>=r+0)?2:(v+0>=a+0)?1:0}'
}
lvl_low() { # value amber red, lower is worse
  [ -n "$1" ] || { echo -1; return; }
  awk -v v="$1" -v a="$2" -v r="$3" 'BEGIN{print (v+0<=r+0)?2:(v+0<=a+0)?1:0}'
}

s_cpu=$(lvl "$cpu" "$CPU_AMBER" "$CPU_RED")
s_ram=$(lvl "$ram" "$RAM_AMBER" "$RAM_RED")
if [ -n "$mem" ]; then # macOS: the worse of RAM in use and the kernel's pressure level
  s_mem=$(awk -v m="$mem" 'BEGIN{print (m>=4)?2:(m>=2)?1:0}')
  [ "$s_mem" -gt "$s_ram" ] && s_ram=$s_mem
fi
s_swap=$(lvl "$swap" "$SWAP_AMBER" "$SWAP_RED")
# macOS: swap is shown only (-2: no color, no level).
[ "$OS" = Darwin ] && [ -n "$swap" ] && s_swap=-2
s_disk=$(lvl_low "$disk" "$DISK_AMBER" "$DISK_RED")
if [ -n "$load1" ] && [ -n "$cores" ]; then
  la=$(awk -v f="$LOAD_AMBER_X" -v c="$cores" 'BEGIN{printf "%.2f", f*c}')
  lr=$(awk -v f="$LOAD_RED_X" -v c="$cores" 'BEGIN{printf "%.2f", f*c}')
  s_load=$(lvl "$load1" "$la" "$lr")
else
  s_load=-1
fi

worst=-1
for x in $s_cpu $s_ram $s_swap $s_load $s_disk; do
  [ "$x" -gt "$worst" ] && worst=$x
done

case $worst in
  2) level=RED;     verdict="heavy commands blocked" ;;
  1) level=AMBER;   verdict="caution" ;;
  0) level=OK;      verdict="clear" ;;
  *) level=UNKNOWN; verdict="no reading" ;;
esac

# ---- output ----

if [ -z "${NO_COLOR:-}" ]; then
  RST=$(printf '\033[0m')
  col_for() { case $1 in 2) printf '\033[31m' ;; 1) printf '\033[33m' ;; 0) printf '\033[32m' ;; -2) ;; *) printf '\033[2m' ;; esac; }
else
  RST=""
  col_for() { :; }
fi

fmt_load() { awk -v v="$1" 'BEGIN{printf "%.1f", v}'; }
fmt_disk() { awk -v v="$1" 'BEGIN{ if (v<10) printf "%.1fG", v; else printf "%.0fG", v }'; }

seg() { # level text
  _c=$(col_for "$1")
  if [ -n "$_c" ]; then printf '%s%s%s' "$_c" "$2" "$RST"; else printf '%s' "$2"; fi
}

t_cpu="CPU n/a";   [ -n "$cpu" ]   && t_cpu="CPU ${cpu}%"
t_ram="RAM n/a";   [ -n "$ram" ]   && t_ram="RAM ${ram}%"
t_swap="swap n/a"; [ -n "$swap" ]  && t_swap="swap ${swap}%"
t_load="load n/a"; [ -n "$load1" ] && t_load="load $(fmt_load "$load1")"
t_disk="disk n/a"; [ -n "$disk" ]  && t_disk="disk $(fmt_disk "$disk")"
t_level="pressure $level"

jnum() { if [ -n "$1" ]; then printf '%s' "$1"; else printf 'null'; fi; }
case $mem in
  '') j_mem=null ;;
  1) j_mem='"normal"' ;;
  2|3) j_mem='"warn"' ;;
  *) j_mem='"critical"' ;;
esac

case "${1:-}" in
  --json)
    printf '{"level":"%s","verdict":"%s","cpu_pct":%s,"ram_pct":%s,"swap_pct":%s,"load1":%s,"cores":%s,"disk_free_gb":%s,"mem_pressure":%s}\n' \
      "$level" "$verdict" "$(jnum "$cpu")" "$(jnum "$ram")" "$(jnum "$swap")" "$(jnum "$load1")" \
      "$(jnum "$cores")" "$(jnum "$disk")" "$j_mem"
    ;;
  --statusline)
    printf '%s | %s | %s | %s | %s | %s\n' "$(seg "$s_cpu" "$t_cpu")" "$(seg "$s_ram" "$t_ram")" \
      "$(seg "$s_swap" "$t_swap")" "$(seg "$s_load" "$t_load")" "$(seg "$s_disk" "$t_disk")" \
      "$(seg "$worst" "$t_level")"
    ;;
  --field)
    case "${2:-}" in
      cpu)   seg "$s_cpu" "$t_cpu" ;;
      ram)   seg "$s_ram" "$t_ram" ;;
      swap)  seg "$s_swap" "$t_swap" ;;
      load)  seg "$s_load" "$t_load" ;;
      disk)  seg "$s_disk" "$t_disk" ;;
      level|verdict) seg "$worst" "$t_level" ;;
      *) echo "usage: pressure.sh --field cpu|ram|swap|load|disk|level" >&2; exit 2 ;;
    esac
    ;;
  ""|--human)
    printf '%s | %s | %s | %s | %s | %s | %s\n' "$level" "$t_cpu" "$t_ram" "$t_swap" "$t_load" "$t_disk" "$verdict"
    ;;
  *)
    echo "usage: pressure.sh [--json | --statusline | --field NAME]" >&2; exit 2
    ;;
esac
