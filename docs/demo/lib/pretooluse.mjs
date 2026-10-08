// pretooluse '<command>' (a function in demo.sh) does what Claude Code does
// before an agent's Bash call. It builds the PreToolUse JSON, reads each demo plugin's hooks/hooks.json, runs
// every Bash PreToolUse hook command through sh with that JSON on stdin and
// CLAUDE_PLUGIN_ROOT set, and prints each hook's decision. The reason text is the
// hook's own output; this file only wraps it and colors it.
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

// demo.sh passes the command in the environment: on the command line it would show
// up in the process list, and machine-pressure's gate would count this process as
// an e2e run already going.
const command = process.env.DEMO_COMMAND
if (!command) {
  process.stderr.write("usage: pretooluse '<bash command>'\n")
  process.exit(2)
}
const pluginsDir = process.env.DEMO_PLUGINS
const parts = (process.env.DEMO_HOOKED || 'git-guardrails machine-pressure').split(/\s+/).filter(Boolean)
const dataDir = process.env.DEMO_PLUGIN_DATA || process.env.TMPDIR
const width = Math.min(process.stdout.columns || 90, 100) - 2

const input = JSON.stringify({
  session_id: 'demo-session',
  transcript_path: path.join(process.env.HOME, '.claude', 'projects', 'demo', 'demo-session.jsonl'),
  cwd: process.cwd(),
  permission_mode: 'default',
  hook_event_name: 'PreToolUse',
  tool_name: 'Bash',
  tool_input: { command, description: 'Run a command' },
  tool_use_id: 'toolu_demo',
})

const results = []
for (const part of parts) {
  const root = path.join(pluginsDir, part)
  const config = JSON.parse(fs.readFileSync(path.join(root, 'hooks', 'hooks.json'), 'utf8'))
  for (const group of config.hooks?.PreToolUse ?? []) {
    if (group.matcher && !new RegExp(`^(?:${group.matcher})$`).test('Bash')) continue
    for (const hook of group.hooks ?? []) {
      if (hook.type !== 'command') continue
      const run = spawnSync('/bin/sh', ['-c', hook.command], {
        input,
        encoding: 'utf8',
        timeout: 60_000,
        env: { ...process.env, CLAUDE_PLUGIN_ROOT: root, CLAUDE_PLUGIN_DATA: path.join(dataDir, part), CLAUDE_PROJECT_DIR: process.cwd() },
      })
      let out = null
      try { out = JSON.parse(run.stdout) } catch {}
      const spec = out?.hookSpecificOutput ?? {}
      if (run.status === 2) results.push({ part, decision: 'deny', text: run.stderr.trim() })
      else if (spec.permissionDecision === 'deny' || spec.permissionDecision === 'ask') {
        results.push({ part, decision: spec.permissionDecision, text: spec.permissionDecisionReason ?? '' })
      } else {
        if (spec.additionalContext) results.push({ part, decision: 'note', text: spec.additionalContext })
        if (out?.systemMessage) results.push({ part, decision: 'note', text: out.systemMessage })
      }
    }
  }
}

const BADGE = { deny: '\x1b[1;97;41m DENY \x1b[0m', ask: '\x1b[1;30;43m ASK \x1b[0m', note: '\x1b[1;30;43m NOTE \x1b[0m' }
const LEAD = '\x1b[1;97m'
const REST = '\x1b[38;5;250m'
const RESET = '\x1b[0m'

// Word-wraps the reason to the terminal, the first sentence bright, the rest dimmer.
function wrap(text) {
  const cut = text.search(/\.\s/)
  const leadLen = cut < 0 ? text.length : cut + 1
  const lines = []
  let line = '', len = 0, pos = 0
  for (const word of text.split(/\s+/)) {
    const at = text.indexOf(word, pos)
    pos = at + word.length
    const styled = (at < leadLen ? LEAD : REST) + word + RESET
    if (len && len + 1 + word.length > width - 2) { lines.push(line); line = ''; len = 0 }
    line += (len ? ' ' : '') + styled
    len += (len ? 1 : 0) + word.length
  }
  if (line) lines.push(line)
  return lines.map((l) => `  ${l}`).join('\n')
}

if (!results.some((r) => r.decision === 'deny' || r.decision === 'ask')) {
  process.stdout.write('\x1b[1;30;42m ALLOW \x1b[0m no hook objected\n')
}
for (const r of results) process.stdout.write(`${BADGE[r.decision]} \x1b[1m${r.part}\x1b[0m\n${wrap(r.text)}\n`)
