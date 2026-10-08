#!/bin/sh
# command_heads: reduce a Bash tool command to what it actually executes.
#
# Prints one line per simple command: the executable, plus the next few words
# only for launchers whose meaning lives in their arguments (npm run X, docker
# compose, npx playwright test, cargo build ...). Text that is data rather than
# a command is dropped first: heredoc bodies and single or double quoted text.
# Leading VAR=val assignments and transparent wrappers (nohup, env, cross-env,
# time, nice, command, exec, timeout N) are skipped, so `nohup env X=1 npm test`
# reads as npm. A command whose leading assignments include PRESSURE_ALLOW=1
# keeps that word in front of its line.
#
# Why: matching the raw command text blocks harmless commands, such as a PR
# body that mentions "e2e", `ps | grep jest`, or `cat jest.config.js`.
# Classify on the heads instead.
#
# Limit (it fails open): `sh -c "npm install"` is quoted, so it is not seen.
#
# Usage: . scripts/command-heads.sh; heads=$(command_heads "$cmd")

command_heads() {
  printf '%s\n' "$1" | awk '
    BEGIN { skip = "" }
    {
      line = $0
      if (skip != "") { if (line == skip) skip = ""; next }
      # A heredoc starts on this line: keep the line, drop the body that follows.
      if (match(line, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
        tag = substr(line, RSTART, RLENGTH)
        gsub(/<<-?[ \t]*["'"'"']?/, "", tag); gsub(/["'"'"']$/, "", tag)
        skip = tag
      }
      # Quoted text is data, not a command.
      gsub(/'"'"'[^'"'"']*'"'"'/, "", line)
      gsub(/"[^"]*"/, "", line)
      # Redirections that contain & (2>&1, >&2, &>) are not separators.
      gsub(/[0-9]*[<>]&[0-9-]*/, " ", line); gsub(/&>>?/, " >", line)
      # Split into simple commands on the shell control operators, a lone & included.
      n = split(line, seg, /(\|\||&&|;|\||&|\$\(|\()/)
      for (i = 1; i <= n; i++) {
        m = split(seg[i], w, /[ \t]+/)
        j = 1; allow = 0
        while (j <= m) {
          if (w[j] == "PRESSURE_ALLOW=1") allow = 1
          if (w[j] == "" || w[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { j++; continue }
          if (w[j] ~ /^(nohup|env|cross-env|time|nice|command|exec)$/) { j++; continue }
          if (w[j] == "sudo") { j++; while (j <= m && w[j] ~ /^-/) { if (w[j] ~ /^-[ugUChprtDT]$/) j++; j++ }; continue }
          if (w[j] == "timeout") { j++; if (j <= m && w[j] ~ /^[0-9]/) j++; continue }
          break
        }
        if (j > m) continue
        head = w[j]
        out = head
        if (head ~ /^(python[0-9.]*|\.\/gradlew|gradlew)$/ || head ~ /^(npm|npx|pnpm|yarn|bun|bunx|node|cargo|go|turbo|make|mvn|gradle|docker|docker-compose|sh|bash|zsh)$/) {
          # docker compose takes options such as -f a.yml -f b.yml before its subcommand.
          lim = (head ~ /^docker/) ? 9 : 5
          for (k = j + 1; k <= m && k <= j + lim; k++) out = out " " w[k]
        }
        print (allow ? "PRESSURE_ALLOW=1 " : "") out
      }
    }'
}
