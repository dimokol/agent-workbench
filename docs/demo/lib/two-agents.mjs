// Scene 3: "api agent" and "web agent" side by side. Each agent starts its own
// copy of the real plugins/agent-chat/server/server.mjs over stdio, the way two
// Claude Code sessions would, and calls its post and wait tools over MCP. The two
// servers share nothing but the AGENT_CHAT_ROOT folder, so the web agent's wait
// returns only when the api agent's post lands on disk, and the other way round.
// The panes are drawn here (no tmux needed). Every message and cursor shown comes
// from the servers' replies; only the message bodies the agents send are scripted.
import { spawn } from 'node:child_process'
import path from 'node:path'

const SERVER = path.join(process.env.DEMO_PLUGINS, 'agent-chat', 'server', 'server.mjs')
const ROOM = 'search-api'
const PROPOSAL = 'Proposing `etaMinutes: number` on Order. OK?'
const REPLY = 'Yes. I\'ll show it as "about 25 min" on the order card.'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---- a minimal MCP client over stdio, one server process per agent ----------
function mcpServer() {
  const proc = spawn(process.execPath, [SERVER], { cwd: process.cwd(), env: process.env, stdio: ['pipe', 'pipe', 'ignore'] })
  const pending = new Map()
  let buf = '', next = 0
  proc.stdout.on('data', (d) => {
    buf += d
    let i
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i)
      buf = buf.slice(i + 1)
      let msg
      try { msg = JSON.parse(line) } catch { continue }
      if (pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id) }
    }
  })
  const rpc = (method, params) => new Promise((res) => {
    const id = ++next
    pending.set(id, res)
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
  })
  return {
    proc,
    async init() {
      await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'demo', version: '1' } })
      proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n')
    },
    async tool(name, args) {
      const msg = await rpc('tools/call', { name, arguments: args })
      const text = msg.result?.content?.[0]?.text ?? ''
      if (msg.result?.isError) throw new Error(text)
      return JSON.parse(text)
    },
  }
}

// ---- two panes ---------------------------------------------------------------
const COLS = process.stdout.columns || 90
const ROWS = process.stdout.rows || 23
const TOP = 3 // the caption and a blank line sit above
const LEFT_W = Math.floor((COLS - 3) / 2)
const RIGHT_X = LEFT_W + 4
const RIGHT_W = COLS - RIGHT_X + 1
const BODY_TOP = TOP + 2
const BODY_H = ROWS - BODY_TOP + 1

const S = {
  api: '1;38;5;75', web: '1;38;5;213', tool: '1;97', arg: '38;5;245', text: '97',
  code: '38;5;221', ok: '38;5;114', dim: '38;5;242', rule: '38;5;238',
}
const sgr = (style, text) => (style ? `\x1b[${style}m${text}\x1b[0m` : text)

class Pane {
  constructor(x, width) { this.x = x; this.width = width; this.lines = [] }
  add(segs, indent = 0, hang = indent) { const line = { segs, indent, hang }; this.lines.push(line); draw(); return line }
  set(line, segs) { line.segs = segs; draw() }
  visual() {
    const out = []
    for (const line of this.lines) out.push(...wrap(line, this.width))
    return out.slice(-BODY_H)
  }
}

// Word-wraps styled segments to `width`: `indent` spaces before the first row,
// `hang` before the rest.
function wrap(line, width) {
  const words = []
  for (const s of line.segs) for (const w of s.text.split(/( )/)) if (w) words.push({ style: s.style, text: w })
  const rows = []
  let row, len, fresh
  const start = (n) => { row = [{ style: '', text: ' '.repeat(n) }]; len = n; fresh = true }
  const push = () => { while (row.length > 1 && row[row.length - 1].text === ' ') { row.pop(); len-- } rows.push(row) }
  start(line.indent)
  for (const w of words) {
    if (w.text === ' ') { if (!fresh) { row.push(w); len++ } continue }
    if (!fresh && len + w.text.length > width) { push(); start(line.hang) }
    row.push(w)
    len += w.text.length
    fresh = false
  }
  push()
  return rows.map((r) => ({ text: r.map((w) => sgr(w.style, w.text)).join(''), len: r.reduce((n, w) => n + w.text.length, 0) }))
}

const left = new Pane(1, LEFT_W)
const right = new Pane(RIGHT_X, RIGHT_W)
const at = (row, col) => `\x1b[${row};${col}H`

function draw() {
  let out = ''
  for (const pane of [left, right]) {
    const rows = pane.visual()
    for (let i = 0; i < BODY_H; i++) {
      const r = rows[i] ?? { text: '', len: 0 }
      out += at(BODY_TOP + i, pane.x) + r.text + ' '.repeat(Math.max(0, pane.width - r.len))
    }
  }
  process.stdout.write(out)
}

function frame() {
  let out = '\x1b[?25l'
  out += at(TOP, 1) + sgr(S.api, ' api agent') + at(TOP, RIGHT_X) + sgr(S.web, ' web agent')
  out += at(TOP + 1, 1) + sgr(S.rule, '─'.repeat(LEFT_W + 1) + '┼' + '─'.repeat(RIGHT_W + 1))
  for (let r = TOP; r <= ROWS; r++) if (r !== TOP + 1) out += at(r, LEFT_W + 2) + sgr(S.rule, '│')
  process.stdout.write(out)
}

// Message text, with `code` spans tinted (an unclosed one too, while it streams).
const body = (text, style = S.text) => text.split(/(`[^`]*`?)/).filter(Boolean).map((t) => ({ style: t.startsWith('`') ? S.code : style, text: t }))

async function stream(pane, text) {
  const line = pane.add([], 2)
  for (let i = 1; i <= text.length; i++) {
    pane.set(line, body(text.slice(0, i)))
    await sleep(16)
  }
}

const step = (pane, name, args) => {
  if (pane.lines.length) pane.add([])
  pane.add([{ style: S.tool, text: `▸ ${name} ` }, { style: S.arg, text: args }], 0, 2)
}

async function post(pane, server, me, to, text) {
  step(pane, 'post', `${ROOM}, to ${to}`)
  await sleep(250)
  await stream(pane, text)
  const r = await server.tool('post', { room: ROOM, from: me, to, message: text })
  pane.add([{ style: S.ok, text: `sent, cursor ${r.cursor}` }], 2)
  return r.cursor
}

async function wait(pane, server, me, after) {
  step(pane, 'wait', ROOM)
  const line = pane.add([{ style: S.dim, text: 'waiting' }], 2, 4)
  let dots = 0
  const tick = setInterval(() => pane.set(line, [{ style: S.dim, text: `waiting${'.'.repeat(++dots % 4)}` }]), 220)
  const r = await server.tool('wait', { room: ROOM, me, after_cursor: after, timeout_seconds: 60 })
  clearInterval(tick)
  const m = r.messages[0]
  pane.set(line, [{ style: S[m.from] ?? S.tool, text: `${m.from}: ` }, ...body(m.message)])
  return r.next_cursor
}

const api = mcpServer()
const web = mcpServer()
const servers = [api, web]
let exiting = false
function shutdown() {
  if (exiting) return
  exiting = true
  for (const s of servers) { try { s.proc.stdin.end(); s.proc.kill() } catch {} }
  process.stdout.write(`${at(ROWS, 1)}\x1b[?25h\n`)
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)

await Promise.all(servers.map((s) => s.init()))
await api.tool('create_room', { title: 'Search API', room: ROOM })
frame()
draw()

const apiAgent = (async () => {
  await sleep(900)
  const cursor = await post(left, api, 'api', 'web', PROPOSAL)
  await sleep(450)
  await wait(left, api, 'api', cursor)
})()

const webAgent = (async () => {
  await sleep(350)
  const cursor = await wait(right, web, 'web', 0)
  await sleep(900)
  await post(right, web, 'web', 'api', REPLY)
  return cursor
})()

await Promise.all([apiAgent, webAgent])
// Hold the last frame; the tape stops recording before this ends.
await sleep(Number(process.env.DEMO_HOLD_MS) || 15_000)
shutdown()
