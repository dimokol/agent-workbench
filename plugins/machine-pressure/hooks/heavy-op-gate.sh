#!/bin/sh
# PreToolUse hook (matcher: Bash). Gates heavy commands on machine pressure and
# on how many heavy runs are already going.
#
# Heavy classes: e2e, docker, install, build, tests, plus anything matching
# extra_heavy_patterns. Everything else passes untouched.
#   - e2e and docker: denied while max_parallel_heavy runs of that class are
#     already active (counted live from the process list, so a crashed run never
#     leaves a stale lock).
#   - RED pressure: any heavy class is denied.
#   - AMBER pressure: the command runs, with a warning added to the context.
#
# Fails open: a missing tool, an unreadable probe or an unknown platform allows
# the command. Override one command with PRESSURE_ALLOW=1 directly before it
# (cd app && PRESSURE_ALLOW=1 npm run build), or at the start of the whole line.
#
# Settings (CLAUDE_PLUGIN_OPTION_<KEY>, else MACHINE_PRESSURE_<KEY>, else default):
#   MAX_PARALLEL_HEAVY (1), EXTRA_HEAVY_PATTERNS (empty), IGNORE_RUNNING_PATTERNS (empty).
# Test hooks: MACHINE_PRESSURE_DEBUG=1 prints the class and stops;
#   PRESSURE_PROBE points at another probe script.

set -u
set -f

TMP=${TMPDIR:-/tmp}; TMP=${TMP%/}

if ! command -v jq >/dev/null 2>&1; then
  marker="$TMP/machine-pressure-nojq-$PPID"
  if [ ! -e "$marker" ]; then
    : > "$marker" 2>/dev/null
    printf '%s\n' '{"systemMessage":"machine-pressure: jq is not installed, so the heavy-command gate is off. Install jq to turn it on."}'
  fi
  exit 0
fi

ROOT=${CLAUDE_PLUGIN_ROOT:-}
if [ -z "$ROOT" ]; then
  case $0 in */*) ROOT=${0%/*}/.. ;; *) ROOT=.. ;; esac
fi
PROBE=${PRESSURE_PROBE:-$ROOT/scripts/pressure.sh}
HEADS_LIB=$ROOT/scripts/command-heads.sh

cfg() { # key default
  _u=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
  eval "_v=\${CLAUDE_PLUGIN_OPTION_$_u:-}"
  [ -n "$_v" ] || eval "_v=\${MACHINE_PRESSURE_$_u:-}"
  printf '%s' "${_v:-$2}"
}

input=$(cat 2>/dev/null) || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Override for the whole line: PRESSURE_ALLOW=1 among its leading VAR=value words.
has_override() {
  rest=$1
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || return 1
    w=${rest%%[[:space:]]*}
    name=${w%%=*}
    case $w in
      *=*) ;;
      *) return 1 ;;
    esac
    case $name in
      ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    [ "$w" = "PRESSURE_ALLOW=1" ] && return 0
    rest=${rest#"$w"}
  done
}
has_override "$cmd" && exit 0

[ -r "$HEADS_LIB" ] || exit 0
. "$HEADS_LIB"
heads=$(command_heads "$cmd")

patterns() { # key: one regex per line, from a JSON array or a comma list
  _p=$(cfg "$1" "")
  case $_p in
    \[*) printf '%s' "$_p" | jq -r '.[]' 2>/dev/null ;;
    *) printf '%s' "$_p" | tr ',' '\n' ;;
  esac
}
extra=$(patterns extra_heavy_patterns)

# Only compose subcommands that start or build containers are heavy. The rest
# (exec, logs, ps, down, cp ...) read, attach or free memory.
compose_kind() { # words of a docker compose line
  set -- $1
  shift
  [ "${1:-}" = compose ] && shift
  while [ $# -gt 0 ]; do
    case $1 in
      -f|--file|-p|--project-name|--profile|--env-file|--project-directory|--ansi|--progress|--parallel)
        shift; [ $# -gt 0 ] && shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  case ${1:-} in
    '') echo heavy ;; # the line was cut off before the subcommand
    up|build|run|create|start|restart|pull|watch|scale) echo heavy ;;
    *) echo light ;;
  esac
}

classify_line() {
  case "$1" in
    # Light, always allowed: browser-free unit runners and commands that free memory.
    *"test:unit"*|*"e2e:down"*|*"e2e:status"*|*"e2e:reset"*|*"e2e:stop"*) return ;;
    *"playwright test -c playwright.unit"*|*"playwright test --config=playwright.unit"*|*"playwright test --config playwright.unit"*) return ;;
    "docker compose"*|"docker-compose"*)
      if [ "$(compose_kind "$1")" = light ]; then return; fi
      echo docker; return ;;
    "docker build"*|"docker run"*) echo docker; return ;;
    *"test:e2e"*|*"e2e:up"*|*"e2e.sh"*|*"playwright test"*|*"cypress run"*) echo e2e; return ;;
    "npm install"*|"npm ci"*|"npm i"|"npm i "*|"pnpm install"*|"pnpm i"|"pnpm i "*|"yarn install"*|"yarn"|"bun install"*|"pnpm add"*|"yarn add"*|"bun add"*) echo install; return ;;
    "npm run build"*|"pnpm build"*|"pnpm run build"*|"yarn build"*|"bun run build"*|"cargo build"*|*"next build"*|*"vite build"*|*"tsc --build"*|*"tsc -b"*) echo build; return ;;
    "turbo "*" build"*|"make build"*|"make "*" build"*|"mvn "*package*|"gradle "*build*|"./gradlew "*build*|"gradlew "*build*) echo build; return ;;
    "pytest"*|"python -m pytest"*|"python3 -m pytest"*|"python"[0-9.]*" -m pytest"*|"cargo test"*|"go test"*) echo tests; return ;;
    "turbo "*" test"*|"make test"*|"make "*" test"*|"mvn "*test*|"gradle "*test*|"./gradlew "*test*|"gradlew "*test*) echo tests; return ;;
  esac
  query=""
  case "$1" in
    "npm "*|"pnpm "*|"yarn "*|"bun "*)
      case "$1" in
        # Asking about a package, or removing one, runs nothing.
        *" view "*|*" info "*|*" search "*|*" why "*|*" explain "*|*" help "*|*" ls "*|*" add "*|*" remove "*|*" uninstall "*) query=1 ;;
        *" build"|*" build "*|*" build:"*) echo build; return ;;
        *" e2e"|*" e2e "*|*" e2e:"*) echo e2e; return ;;
      esac ;;
  esac
  if [ -z "$query" ]; then
    case "$1" in
      "npm "*|"npx "*|"pnpm "*|"yarn "*|"bun "*|"bunx "*|"node "*|vitest*|jest*)
        case "$1" in
          *vitest*|*jest*|*"test:affected"*|*" test"|*" test "*) echo tests; return ;;
        esac ;;
    esac
  fi
  if [ -n "$extra" ]; then
    printf '%s\n' "$extra" | while IFS= read -r p; do
      [ -n "$p" ] && printf '%s\n' "$1" | grep -Eq -- "$p" && { echo heavy; break; }
    done
  fi
}

# First heavy command in a chain wins, so a light command earlier in the chain
# cannot hide a heavy one after it. A command with its own PRESSURE_ALLOW=1 passes.
class=""
while IFS= read -r line; do
  case $line in ''|"PRESSURE_ALLOW=1 "*) continue ;; esac
  c=$(classify_line "$line")
  if [ -n "$c" ]; then class=$c; break; fi
done <<EOF_HEADS
$heads
EOF_HEADS

if [ "${MACHINE_PRESSURE_DEBUG:-}" = "1" ]; then
  printf 'class=%s\n' "${class:-none}"
  exit 0
fi
[ -n "$class" ] || exit 0

# Live count of running commands in this class, across all sessions. A child
# process whose parent also matches belongs to the same run and is not counted.
pat=""; xpat=""
case $class in
  e2e)     pat='playwright test|cypress run|test:e2e|e2e:up|e2e[.]sh|(npm|pnpm|yarn|bun)( run)? e2e( |:|$)'
           xpat='playwright[.]unit|test:unit|e2e:(down|status|reset|stop)' ;;
  # A compose line counts by its subcommand (the heavy list in compose_kind), read past
  # global options, so `docker compose exec app npm run build` is not a run.
  docker)  pat='docker[ -]compose( compose)?( +-[^ ]+( +[^ -][^ ]*)?)* +(up|build|run|create|start|restart|pull|watch|scale)( |$)|docker (buildx )?build|docker buildx|docker run' ;;
  install) pat='npm (install|ci)|npm i( |$)|pnpm (install|i)( |$)|yarn install|bun install|yarn$' ;;
  build)   pat='npm run build|pnpm (run )?build|yarn build|next build|tsc (--build|-b)|cargo build|vite build|turbo (run )?build|mvn .*package|gradlew? .*build' ;;
  tests)   pat='vitest|jest|npm test|npm run test|pnpm test|yarn test|pytest|cargo test|go test|turbo (run )?test|mvn .*test|gradlew? .*test' ;;
esac
# Processes matching ignore_running_patterns never count, joined into one regex.
ignore=$(patterns ignore_running_patterns | awk 'NF { printf "%s(%s)", (n++ ? "|" : ""), $0 }')
running=0
if [ -n "$pat" ]; then
  procs=$(ps -A -o pid=,ppid=,command= 2>/dev/null)
  n=$(printf '%s\n' "$procs" | IGNORE="$ignore" awk -v pat="$pat" -v skip="$xpat" '
    # A docker run with -i and no tty talks over stdin and stdout: a stdio MCP server
    # that lives as long as its session, not a run.
    function stdio_run(cmd,   w, n, i, x, inter, tty) {
      n = split(cmd, w, /[ \t]+/)
      for (i = 2; i <= n && !(w[i] == "run" && w[i - 1] ~ /(^|\/)docker$/); i++) ;
      for (i++; i <= n; i++) {
        x = w[i]
        if (x !~ /^-/) break # the image
        if (x ~ /^--interactive(=true)?$/) inter = 1
        else if (x ~ /^--tty(=true)?$/) tty = 1
        else if (x ~ /^-[dPqit]+$/) { if (x ~ /i/) inter = 1; if (x ~ /t/) tty = 1 }
        else if (x ~ /^-[a-zA-Z]$/ || (x ~ /^--/ && x !~ /=/ && x !~ /^--(rm|detach|init|privileged|read-only|publish-all|no-healthcheck|oom-kill-disable|quiet|sig-proxy|disable-content-trust)$/)) i++ # its value
      }
      return inter && !tty
    }
    BEGIN { ign = ENVIRON["IGNORE"] }
    { pid = $1; ppid = $2; cmd = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd)
      split(cmd, a, " "); k = split(a[1], b, "/"); base = b[k]
      if (base ~ /^(grep|egrep|rg|pgrep|ps|tail|less|cat|vi|vim|nano|git|awk|sed)$/) next
      if (cmd !~ pat) next
      if (skip != "" && cmd ~ skip) next
      if (ign != "" && cmd ~ ign) next
      if (cmd ~ /docker run/ && stdio_run(cmd)) next
      hit[pid] = 1; par[pid] = ppid }
    END { c = 0; for (p in hit) if (!(par[p] in hit)) c++; print c }' 2>/dev/null)
  case $n in ''|*[!0-9]*) n=0 ;; esac
  running=$n
fi

max=$(cfg max_parallel_heavy 1)
case $max in ''|*[!0-9]*) max=1 ;; esac
[ "$max" -ge 1 ] || max=1

pj=$(sh "$PROBE" --json 2>/dev/null)
level=$(printf '%s' "$pj" | jq -r '.level // "UNKNOWN"' 2>/dev/null); level=${level:-UNKNOWN}
summary=$(printf '%s' "$pj" | jq -r 'def v(x): if x == null then "n/a" else (x|tostring) end;
  "CPU \(v(.cpu_pct))%, RAM \(v(.ram_pct))%, swap \(v(.swap_pct))%, load \(v(.load1)), disk \(v(.disk_free_gb)) GB free"' 2>/dev/null)
[ -n "$summary" ] || summary="no machine reading"

emit() { # deny|warn, message
  printf '%s' "$2" | jq -Rs --arg d "$1" \
    '{hookSpecificOutput: ({hookEventName:"PreToolUse"} + (if $d=="deny" then {permissionDecision:"deny", permissionDecisionReason:.} else {additionalContext:.} end))}'
  exit 0
}

tip="To run it anyway, put PRESSURE_ALLOW=1 directly before the heavy command, after any cd (cd app && PRESSURE_ALLOW=1 npm run build). Each heavy command in a chain needs its own."

if { [ "$class" = e2e ] || [ "$class" = docker ]; } && [ "$running" -ge "$max" ]; then
  emit deny "Blocked: $running $class run(s) already active, and the limit is $max (max_parallel_heavy). Another session or terminal is using the machine for the same job. Wait for it to finish, then retry. Machine: $summary. $tip"
fi

if [ "$level" = RED ]; then
  emit deny "Blocked: machine pressure is RED ($summary), so this $class command could freeze the machine. Free memory first (close idle agent sessions or stop dev servers), then retry. $tip"
elif [ "$level" = AMBER ]; then
  emit warn "Machine pressure is AMBER ($summary). $running $class run(s) already active. The command will run, but consider closing idle sessions before starting more heavy work."
fi

exit 0
