#!/bin/sh
# Gate tests: heavy-op-gate.sh with a stub probe and a stub process list.
HERE=$(cd "$(dirname "$0")" && pwd)
H=$HERE/../hooks/heavy-op-gate.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/nojq"
pass=0; fail=0

ok() { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1 (got: $2)"; }

# The stub probe prints whatever is in $WORK/probe.json.
printf '#!/bin/sh\ncat "%s/probe.json"\n' "$WORK" > "$WORK/probe.sh"
set_level() { # LEVEL
  printf '{"level":"%s","verdict":"x","cpu_pct":20,"ram_pct":%s,"swap_pct":10,"load1":1.5,"cores":8,"disk_free_gb":80.0}\n' \
    "$1" "$([ "$1" = RED ] && echo 96 || echo 50)" > "$WORK/probe.json"
}
# The stub ps prints $WORK/ps.txt (pid ppid command).
set_ps() { printf '%s\n' "$@" > "$WORK/ps.txt"; }
printf '#!/bin/sh\ncat "%s/ps.txt"\n' "$WORK" > "$WORK/bin/ps"; chmod +x "$WORK/bin/ps"

run() { # command [env assignment...]  -> hook stdout
  c=$1; shift
  printf '%s' "$c" | jq -Rs '{tool_input:{command:.}}' | \
    env PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp" PRESSURE_PROBE="$WORK/probe.sh" "$@" sh "$H"
}
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null; }

expect_allow() { # name command [env]
  n=$1; c=$2; shift 2
  out=$(run "$c" "$@" X_UNUSED=1)
  if [ -z "$out" ]; then ok "$n"; else bad "$n" "$out"; fi
}
expect_deny() { # name command pattern [env]
  n=$1; c=$2; p=$3; shift 3
  out=$(run "$c" "$@" X_UNUSED=1)
  if [ "$(decision "$out")" = deny ] && printf '%s' "$out" | grep -q "$p"; then ok "$n"; else bad "$n" "$out"; fi
}

set_ps "  1 0 /sbin/launchd"

echo "== pressure =="
set_level OK
expect_allow "OK: heavy command runs" 'npm install'
set_level RED
expect_deny "RED: install is denied" 'npm install' 'RED'
expect_deny "RED: the reason names the way forward" 'npm run build' 'PRESSURE_ALLOW=1'
expect_deny "RED: the reason carries the readings" 'npx vitest run' 'RAM 96%'
expect_allow "RED: a light command passes" 'ls -la'
expect_allow "RED: down passes" 'docker compose down'
expect_allow "RED: text mentioning a heavy command passes" 'gh pr create --body "npm install first"'
out=$(run 'npm install' X_UNUSED=1)
if printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null; then ok "deny output is valid hook JSON"; else bad "deny output is valid hook JSON" "$out"; fi
set_level AMBER
out=$(run 'npm run build' X_UNUSED=1)
if [ "$(decision "$out")" = none ] && printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | test("AMBER")' >/dev/null; then ok "AMBER: warns and allows"; else bad "AMBER: warns and allows" "$out"; fi
set_level UNKNOWN
expect_allow "UNKNOWN: allowed" 'npm install'
printf 'not json' > "$WORK/probe.json"
expect_allow "broken probe output: allowed" 'npm install'
rm -f "$WORK/probe.json"
expect_allow "missing probe output: allowed" 'npm install'

echo "== the probe runs in the session's folder =="
mkdir -p "$WORK/small disk"
printf '#!/bin/sh\ncase $(pwd) in *"/small disk") l=RED ;; *) l=OK ;; esac\nprintf "{\\"level\\":\\"%%s\\",\\"mem_pressure\\":\\"normal\\"}\\n" "$l"\n' > "$WORK/cwdprobe.sh"
incwd() { # dir -> hook stdout for npm install run from dir
  jq -nc --arg d "$1" '{cwd:$d,tool_input:{command:"npm install"}}' | \
    env PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp" PRESSURE_PROBE="$WORK/cwdprobe.sh" sh "$H"
}
out=$(incwd "$WORK/small disk")
if [ "$(decision "$out")" = deny ]; then ok "the probe reads the cwd from the hook input"; else bad "the probe reads the cwd from the hook input" "$out"; fi
if printf '%s' "$out" | grep -q 'memory pressure normal'; then ok "the reason carries the memory pressure"; else bad "the reason carries the memory pressure" "$out"; fi
out=$(incwd "$WORK")
if [ -z "$out" ]; then ok "another cwd reads another disk"; else bad "another cwd reads another disk" "$out"; fi

echo "== override must be a leading assignment =="
set_level RED
expect_allow "PRESSURE_ALLOW=1 first" 'PRESSURE_ALLOW=1 npm install'
expect_allow "PRESSURE_ALLOW=1 after another assignment" 'CI=1 PRESSURE_ALLOW=1 npm install'
expect_deny "token in an echo does not count" 'echo PRESSURE_ALLOW=1; npm install' 'RED'
expect_allow "token directly before the heavy command, after cd" 'cd x && PRESSURE_ALLOW=1 npm install'
expect_allow "token after another assignment, after cd" 'cd app && CI=1 PRESSURE_ALLOW=1 npm run build'
expect_deny "each heavy command needs its own token" 'cd x && PRESSURE_ALLOW=1 npm install && npm run build' 'RED'
expect_deny "the reason says where the token goes" 'cd app && npm run build' 'directly before the heavy command'
expect_deny "token in a quoted string does not count" 'npm install --message "PRESSURE_ALLOW=1"' 'RED'
expect_deny "PRESSURE_ALLOW=0 does not count" 'PRESSURE_ALLOW=0 npm install' 'RED'
expect_deny "PRESSURE_ALLOW=10 does not count" 'PRESSURE_ALLOW=10 npm install' 'RED'

echo "== parallel cap for e2e and docker =="
set_level OK
set_ps "  1 0 /sbin/launchd" " 400 1 node /app/node_modules/.bin/playwright test e2e/a.spec.ts"
expect_deny "second e2e run is denied" 'npx playwright test e2e/b.spec.ts' 'already active'
expect_deny "the cap message names the setting" 'npm run test:e2e' 'max_parallel_heavy'
expect_allow "max_parallel_heavy=2 lets a second run start" 'npx playwright test' MACHINE_PRESSURE_MAX_PARALLEL_HEAVY=2
expect_allow "the plugin option sets the cap too" 'npx playwright test' CLAUDE_PLUGIN_OPTION_MAX_PARALLEL_HEAVY=2
expect_allow "a non-e2e heavy command is not capped" 'npm install'
expect_allow "PRESSURE_ALLOW=1 skips the cap" 'PRESSURE_ALLOW=1 npx playwright test'
expect_allow "PRESSURE_ALLOW=1 after cd skips the cap" 'cd fe && PRESSURE_ALLOW=1 npx playwright test'
set_ps "  1 0 /sbin/launchd" " 400 1 npm run test:e2e" " 401 400 sh -c playwright test" " 402 401 node playwright test"
expect_deny "a run and its children count once at cap 1" 'npx playwright test' 'already active'
expect_allow "a run and its children count once at cap 2" 'npx playwright test' MACHINE_PRESSURE_MAX_PARALLEL_HEAVY=2
set_ps "  1 0 /sbin/launchd" " 500 1 grep -r playwright test src" " 501 1 tail -f e2e.sh.log"
expect_allow "grep and tail lines are not runs" 'npx playwright test'
set_ps "  1 0 /sbin/launchd" " 600 1 node playwright test -c playwright.unit.config.ts"
expect_allow "unit-config playwright runs are not counted" 'npx playwright test'
set_ps "  1 0 /sbin/launchd" " 700 1 docker compose -f stack.yml up -d"
expect_deny "second docker run is denied" 'docker compose up' 'already active'
expect_allow "docker down is never capped" 'docker compose down'
set_ps "  1 0 /sbin/launchd" " 710 1 docker compose logs -f"
expect_allow "docker logs is not a run" 'docker compose up'
set_ps "  1 0 /sbin/launchd" " 700 1 docker compose up"
expect_allow "compose exec runs beside an attached up" 'docker compose exec app rails db:migrate'
expect_allow "compose exec with npm run in it" 'docker compose exec app npm run lint'
expect_allow "compose exec into a database" 'docker compose exec db psql -U postgres'
set_ps "  1 0 /sbin/launchd" " 720 1 docker compose exec app npm run build"
expect_allow "a running compose exec is not a run" 'docker compose up'
set_ps "  1 0 /sbin/launchd" " 730 1 /opt/docker/cli-plugins/docker-compose compose -f a.yml up"
expect_deny "the compose plugin process counts" 'docker compose up' 'already active'
set_ps "  1 0 /sbin/launchd" " 501 500 docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server"
expect_allow "a stdio MCP server (docker run -i, no tty) is not a run: build" 'docker build -t app .'
expect_allow "a stdio MCP server is not a run: compose up" 'docker compose up -d'
set_ps "  1 0 /sbin/launchd" " 502 1 docker run --interactive -e A=1 -v /x:/y mcp/fetch"
expect_allow "--interactive without a tty is not a run" 'docker compose up -d'
set_ps "  1 0 /sbin/launchd" " 503 1 docker run -it --rm ubuntu bash"
expect_deny "an -it shell still counts" 'docker build -t app .' 'already active'
set_ps "  1 0 /sbin/launchd" " 504 1 docker run -i -t --rm ubuntu bash"
expect_deny "-i -t still counts" 'docker build -t app .' 'already active'
set_ps "  1 0 /sbin/launchd" " 505 1 docker run --rm -v /x:/y app pytest -i"
expect_deny "a job without -i counts, whatever its own arguments are" 'docker build -t app .' 'already active'
set_ps "  1 0 /sbin/launchd" " 506 1 docker run -it --rm --name devdb postgres"
expect_allow "ignore_running_patterns skips a process" 'docker compose up' MACHINE_PRESSURE_IGNORE_RUNNING_PATTERNS=--name.devdb
expect_allow "ignore_running_patterns as a plugin option array" 'docker compose up' 'CLAUDE_PLUGIN_OPTION_IGNORE_RUNNING_PATTERNS=["x","devdb"]'
expect_deny "ignore_running_patterns that match nothing" 'docker compose up' 'already active' MACHINE_PRESSURE_IGNORE_RUNNING_PATTERNS=other
set_ps "  1 0 /sbin/launchd" " 800 1 node /x/node_modules/.bin/playwright test"
expect_deny "npm run e2e waits for a running playwright" 'npm run e2e' 'already active'
expect_deny "pnpm e2e waits too" 'pnpm e2e' 'already active'
set_ps "  1 0 /sbin/launchd" " 810 1 node /usr/local/bin/npm run e2e"
expect_deny "a running npm run e2e counts" 'npx playwright test' 'already active'
set_ps "  1 0 /sbin/launchd" " 820 1 node /usr/local/bin/npm run e2e:down"
expect_allow "a running e2e:down is not a run" 'npx playwright test'
set_level RED
set_ps "  1 0 /sbin/launchd"
expect_allow "RED: npm ls jest only reads" 'npm ls jest'
expect_allow "RED: npm view vitest only reads" 'npm view vitest version'
set_level OK
set_ps "  1 0 /sbin/launchd"
expect_allow "no runs: allowed" 'npx playwright test'

echo "== extra_heavy_patterns =="
set_level RED
expect_allow "unlisted command passes under RED" 'npm run bigjob'
expect_deny "listed command is gated" 'npm run bigjob' 'RED' MACHINE_PRESSURE_EXTRA_HEAVY_PATTERNS=run.bigjob
expect_deny "plugin option, comma list" 'terraform apply' 'RED' 'CLAUDE_PLUGIN_OPTION_EXTRA_HEAVY_PATTERNS=^ffmpeg,^terraform'
expect_deny "plugin option, JSON array" 'ffmpeg -i a b' 'RED' 'CLAUDE_PLUGIN_OPTION_EXTRA_HEAVY_PATTERNS=["^ffmpeg","^terraform"]'

echo "== missing jq: allow, and say so once per session =="
set_level RED
both=$(env PATH="$WORK/nojq" TMPDIR="$WORK/tmp" /bin/sh -c '
  for i in 1 2; do
    echo "[$i]"
    printf "%s" "{\"tool_input\":{\"command\":\"npm install\"}}" | /bin/sh "$0"
  done' "$H")
case $both in
  "[1]
{\"systemMessage\":\"machine-pressure: jq is not installed"*"[2]") ok "warns once, allows both calls" ;;
  *) bad "warns once, allows both calls" "$both" ;;
esac

echo
echo "gate: passed=$pass failed=$fail"
[ "$fail" = 0 ]
