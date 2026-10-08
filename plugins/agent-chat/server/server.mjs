#!/usr/bin/env node
// agent-chat: a tiny zero-dependency MCP server that gives several CLI agents
// (Claude Code, Codex, Gemini, anything that speaks MCP) shared chats.
//
// State lives on disk, so each CLI spawns its own copy of this stdio server and
// they coordinate through the same files. `wait` scans the log, watches the room
// folder, rescans to close the watch race, and keeps a slow fallback scan
// (fs.watch can miss events). See the README for configuration.
//
// Rooms live under the resolved project base:
//     room.json   { id, title, created }
//     chat.jsonl  canonical append-only log (source of truth)
//     chat.md     human-readable transcript (open this to read)
//     .lock       short-lived write lock (per room)

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import readline from 'node:readline'

const MAX_MSG = 200_000 // chars
const MAX_TITLE = 200
const DEFAULT_WAIT_S = 55 // stays under Codex's 60s default tool timeout
const MAX_WAIT_S = 3600
const FALLBACK_SCAN_MS = 1500

// ---- helpers ---------------------------------------------------------------
const norm = (s) => String(s ?? '').trim()
const lc = (s) => norm(s).toLowerCase()
const BROADCAST = new Set(['', 'all', 'everyone', 'any', '*'])

// No leading dot: "." and ".." would put files outside the rooms folder.
function validId(v, field) {
  const s = norm(v)
  if (!/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/.test(s)) throw new Error(`invalid ${field}: must match [A-Za-z0-9._-]{1,64} and not start with a dot`)
  return s
}
function validRecipient(v) {
  const s = norm(v)
  if (s === '' || BROADCAST.has(lc(s))) return s || 'all'
  return validId(s, 'to')
}
function slugify(s) {
  const out = norm(s).toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/-{2,}/g, '-').replace(/^[-.]+|[-.]+$/g, '').slice(0, 64)
  return out || 'room'
}
function newId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
}

function expandHome(p) {
  const s = norm(p)
  if (s === '~') return os.homedir()
  if (s.startsWith('~/') || s.startsWith('~\\')) return path.join(os.homedir(), s.slice(2))
  return s
}

function realpathOrResolve(p) {
  try { return fs.realpathSync.native(p) } catch { return path.resolve(p) }
}

function findGitProjectRoot(start) {
  let dir = realpathOrResolve(start)
  for (;;) {
    const marker = path.join(dir, '.git')
    try {
      const stat = fs.statSync(marker)
      if (stat.isDirectory()) return dir
      if (stat.isFile()) {
        const line = fs.readFileSync(marker, 'utf8').trim()
        const match = /^gitdir:\s*(.+)$/i.exec(line)
        if (match) {
          const gitDir = path.resolve(dir, match[1])
          const worktreesMark = `${path.sep}.git${path.sep}worktrees${path.sep}`
          const splitAt = gitDir.lastIndexOf(worktreesMark)
          if (splitAt >= 0) return realpathOrResolve(gitDir.slice(0, splitAt))
        }
        return dir
      }
    } catch {}
    const parent = path.dirname(dir)
    if (parent === dir) return realpathOrResolve(start)
    dir = parent
  }
}

function readProjectMeta(dir) {
  try { return JSON.parse(fs.readFileSync(path.join(dir, 'project.json'), 'utf8')) } catch { return null }
}

function resolveChatScope() {
  const projectRoot = findGitProjectRoot(process.cwd())
  const forcedProject = norm(process.env.AGENT_CHAT_PROJECT)
  if (forcedProject) validId(forcedProject, 'AGENT_CHAT_PROJECT')

  const explicitDir = expandHome(process.env.AGENT_CHAT_DIR)
  if (explicitDir) {
    return {
      project: forcedProject || slugify(path.basename(projectRoot)),
      projectRoot,
      dir: path.resolve(explicitDir),
    }
  }

  const centralRoot = expandHome(process.env.AGENT_CHAT_ROOT) || path.join(os.homedir(), '.agent-chat')
  const chatsRoot = path.resolve(centralRoot)
  fs.mkdirSync(chatsRoot, { recursive: true })

  // A name set on purpose is used as-is, with no root check and no suffix, so agents in
  // different repos that set the same AGENT_CHAT_PROJECT meet in one bucket.
  if (forcedProject) {
    const dir = path.join(chatsRoot, forcedProject)
    fs.mkdirSync(dir, { recursive: true })
    if (!readProjectMeta(dir)) {
      fs.writeFileSync(path.join(dir, 'project.json'), JSON.stringify({
        id: forcedProject,
        name: forcedProject,
        project_root: projectRoot,
        created: new Date().toISOString(),
      }, null, 2) + '\n')
    }
    return { project: forcedProject, projectRoot, dir }
  }

  const preferred = slugify(path.basename(projectRoot))
  const suffix = crypto.createHash('sha256').update(projectRoot).digest('hex').slice(0, 8)
  let project = preferred
  let dir = path.join(chatsRoot, project)
  const existing = readProjectMeta(dir)
  if (existing && realpathOrResolve(existing.project_root || '') !== projectRoot) {
    project = `${preferred.slice(0, 55)}-${suffix}`
    dir = path.join(chatsRoot, project)
  }

  fs.mkdirSync(dir, { recursive: true })
  const metaPath = path.join(dir, 'project.json')
  const meta = readProjectMeta(dir)
  if (!meta) {
    fs.writeFileSync(metaPath, JSON.stringify({
      id: project,
      name: path.basename(projectRoot),
      project_root: projectRoot,
      created: new Date().toISOString(),
    }, null, 2) + '\n')
  } else if (realpathOrResolve(meta.project_root || '') !== projectRoot) {
    throw new Error(`agent-chat project collision for "${project}"`)
  }

  return { project, projectRoot, dir }
}

const SCOPE = resolveChatScope()
const DIR = SCOPE.dir
const ROOMS = path.join(DIR, 'rooms')
fs.mkdirSync(ROOMS, { recursive: true })

// ---- rooms -----------------------------------------------------------------
function roomPaths(room) {
  const dir = path.join(ROOMS, room)
  return { dir, jsonl: path.join(dir, 'chat.jsonl'), md: path.join(dir, 'chat.md'), lock: path.join(dir, '.lock'), meta: path.join(dir, 'room.json') }
}
function roomExists(room) {
  try { return fs.existsSync(roomPaths(room).meta) } catch { return false }
}
function writeRoomMeta(id, title) {
  const p = roomPaths(id)
  const created = new Date().toISOString()
  fs.mkdirSync(p.dir, { recursive: true })
  fs.writeFileSync(p.meta, JSON.stringify({ id, title, created }, null, 2) + '\n')
  fs.writeFileSync(p.md, `# ${title}\n\n_room \`${id}\` · created ${created}_\n`)
  return created
}
function createRoom({ title, room }) {
  const t = norm(title)
  if (!t) throw new Error('create_room requires a non-empty title')
  if (t.length > MAX_TITLE) throw new Error(`title too long (>${MAX_TITLE} chars)`)
  let id = room ? validId(room, 'room') : slugify(t)
  if (roomExists(id)) {
    if (room) throw new Error(`room "${id}" already exists. Pick another id, or open it with list_rooms`)
    const base = id // title-derived: auto-suffix so a new chat never lands on an existing file
    let n = 2
    while (roomExists(id)) { id = `${base}-${n++}` }
  }
  const created = writeRoomMeta(id, t)
  return { room: id, title: t, created }
}
// Lazy-create a room on first post so a waiter+poster who agreed on an id don't
// have to pre-create. Titled rooms should still go through create_room.
function ensureRoom(room, title) {
  if (roomExists(room)) return
  writeRoomMeta(room, norm(title) || room)
}
function listRooms() {
  let names = []
  try { names = fs.readdirSync(ROOMS, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name) } catch {}
  const out = []
  for (const name of names) {
    const p = roomPaths(name)
    let meta
    try { meta = JSON.parse(fs.readFileSync(p.meta, 'utf8')) } catch { continue } // not a room dir
    const msgs = readMessages(name)
    out.push({ room: meta.id || name, title: meta.title || name, created: meta.created ?? null, messages: msgs.length, last_ts: msgs.length ? msgs[msgs.length - 1].ts : null })
  }
  out.sort((a, b) => String(a.created).localeCompare(String(b.created)))
  return out
}

// ---- tiny cross-process write lock (no dependencies) -----------------------
let heldLock = null
function sleep(ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms) }
function withLock(lockPath, fn) {
  const start = Date.now()
  for (;;) {
    try {
      const fd = fs.openSync(lockPath, 'wx')
      heldLock = lockPath
      try { return fn() } finally { heldLock = null; fs.closeSync(fd); try { fs.unlinkSync(lockPath) } catch {} }
    } catch (e) {
      if (e.code !== 'EEXIST') throw e
      if (Date.now() - start > 4000) { try { fs.unlinkSync(lockPath) } catch {} } // break a stale lock
      sleep(15)
    }
  }
}

// ---- log I/O (per room) ----------------------------------------------------
// seq = position in append order (0-based). cursor = seq + 1. The log is
// append-only and never reordered, so seq is a stable durable ordinal.
function readMessages(room) {
  let raw
  try { raw = fs.readFileSync(roomPaths(room).jsonl, 'utf8') } catch { return [] }
  const out = []
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue
    try { const m = JSON.parse(line); m.seq = out.length; out.push(m) }
    catch { /* a partly-written trailing line; parses cleanly on the next read */ }
  }
  return out
}

function post({ room, from, to, channel, message, reply_to, title }) {
  const r = validId(room, 'room')
  const f = validId(from ?? '', 'from')
  const t = validRecipient(to)
  const ch = channel ? validId(channel, 'channel') : 'main'
  const body = String(message ?? '')
  if (!body.trim()) throw new Error('message is empty')
  if (body.length > MAX_MSG) throw new Error(`message too large (>${MAX_MSG} chars)`)
  const rep = reply_to != null ? String(reply_to).slice(0, 128) : null
  ensureRoom(r, title)
  const p = roomPaths(r)
  const rec = { id: newId(), ts: new Date().toISOString(), from: f, to: t, channel: ch, reply_to: rep, message: body }
  let cursor
  withLock(p.lock, () => {
    const count = readMessages(r).length
    fs.appendFileSync(p.jsonl, JSON.stringify(rec) + '\n')
    const tag = ch === 'main' ? '' : `[${ch}] `
    fs.appendFileSync(p.md, '\n' + `### ${tag}${f} → ${t}  ·  ${rec.ts}  ·  id ${rec.id}` + '\n\n' + body.trimEnd() + '\n')
    cursor = count + 1
  })
  return { room: r, message_id: rec.id, cursor }
}

function isForMe(m, me) {
  if (lc(m.from) === lc(me)) return false // never hand your own message back
  const to = lc(m.to)
  return BROADCAST.has(to) || to === lc(me)
}

// Pure scan: no side effects. Matches with cursor > afterCursor in the room's
// channel addressed to `me`, plus the highest cursor seen (for next_cursor).
function scan(room, afterCursor, me, channel) {
  let next = afterCursor
  const matches = []
  for (const m of readMessages(room)) {
    const cur = m.seq + 1
    if (cur <= afterCursor) continue
    if ((m.channel || 'main') !== channel) { next = Math.max(next, cur); continue }
    next = Math.max(next, cur)
    if (isForMe(m, me)) {
      matches.push({ message_id: m.id, from: m.from, to: m.to, channel: m.channel || 'main', ts: m.ts, reply_to: m.reply_to ?? null, cursor: cur, message: m.message })
    }
  }
  return { matches, next }
}

// In-memory fallback cursor, keyed per (room, channel, me). Advances only on
// delivery, so a cancelled/timed-out wait never skips a message. Agents that
// pass after_cursor get full restart-safety and don't rely on this.
const memCursor = new Map()
const ckey = (room, c, m) => `${lc(room)}\u0000${lc(c)}\u0000${lc(m)}`
const cursorFor = (room, c, m) => memCursor.get(ckey(room, c, m)) ?? 0
const setCursor = (room, c, m, v) => memCursor.set(ckey(room, c, m), v)

function waitForMessages({ room, me, channel, after, timeoutMs }) {
  let cancelFn = () => {}
  const promise = new Promise((resolve) => {
    let done = false
    let watcher = null, timer = null, poll = null
    const cleanup = () => {
      if (watcher) { try { watcher.close() } catch {} watcher = null }
      if (timer) { clearTimeout(timer); timer = null }
      if (poll) { clearInterval(poll); poll = null }
    }
    const finish = (res) => { if (done) return; done = true; cleanup(); resolve(res) }
    const check = () => {
      const { matches, next } = scan(room, after, me, channel)
      if (matches.length) finish({ status: 'ok', reason: 'message', room, messages: matches, next_cursor: next })
    }
    check(); if (done) return          // 1. scan the durable log first
    try {
      // Watch the room dir if it exists, else the rooms root so we still wake
      // when a not-yet-created room appears. fs.watch can fail asynchronously
      // under resource pressure; degrade to the fallback scan instead of crashing.
      const target = roomExists(room) ? roomPaths(room).dir : ROOMS
      watcher = fs.watch(target, check)
      watcher.on('error', () => { if (watcher) { try { watcher.close() } catch {} watcher = null } })
    } catch {} // 2. watch
    check(); if (done) return          // 3. rescan to close the scan/watch race
    poll = setInterval(check, FALLBACK_SCAN_MS) // 4. server-side fallback (no tokens)
    timer = setTimeout(() => finish({ status: 'timeout', reason: 'timeout', room, messages: [], next_cursor: after }), timeoutMs)
    cancelFn = () => finish({ status: 'cancelled', reason: 'cancelled', room, messages: [], next_cursor: after })
  })
  return { promise, cancel: () => cancelFn() }
}

// ---- MCP (JSON-RPC 2.0 over newline-delimited stdio) ------------------------
function send(obj) { process.stdout.write(JSON.stringify(obj) + '\n') }
function result(id, res) { send({ jsonrpc: '2.0', id, result: res }) }
function rpcError(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }) }
function textResult(payload, isError) {
  return { content: [{ type: 'text', text: payload }], ...(isError ? { isError: true } : {}) }
}

const TOOLS = [
  {
    name: 'create_room',
    description:
      'Create a new, isolated, titled chat room in the current project and return its id. Give `title` (human-readable, ' +
      'required) and optional `room` (an explicit slug id). Ids are unique: an explicit id that ' +
      'already exists errors; a title-derived id auto-suffixes so a new chat never lands on an ' +
      'existing transcript. Use this to start a distinct conversation; peers join it by that id.',
    inputSchema: {
      type: 'object',
      properties: {
        title: { type: 'string', description: 'Human-readable room title.' },
        room: { type: 'string', description: 'Explicit room id (slug). Optional; derived from title if omitted.' },
      },
      required: ['title'],
    },
  },
  {
    name: 'list_rooms',
    description: 'List rooms only for the current inferred project, with { room, title, created, messages, last_ts }, so you can discover and join the right conversation by title.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'post',
    description:
      'Post a message to a room in the current inferred project. `room` (required) is the conversation id from create_room / ' +
      'list_rooms. Give `from` (your agent name), optional `to` (who you address; omit or "all"/"*" ' +
      'to broadcast), `message`, optional `channel` (sub-topic within the room, default "main"), ' +
      'optional `reply_to` (a message_id), and optional `title` (only used if the room does not exist ' +
      'yet, to name it). Returns { room, message_id, cursor }.',
    inputSchema: {
      type: 'object',
      properties: {
        room: { type: 'string', description: 'Room id (required).' },
        from: { type: 'string', description: 'Your agent name.' },
        to: { type: 'string', description: 'Who you address. Omit or "all"/"*" to broadcast.' },
        message: { type: 'string', description: 'Message body (may be multi-line).' },
        channel: { type: 'string', description: 'Sub-topic within the room. Default "main".' },
        reply_to: { type: 'string', description: 'message_id this replies to (optional).' },
        title: { type: 'string', description: 'Title used only if the room must be auto-created.' },
      },
      required: ['room', 'from', 'message'],
    },
  },
  {
    name: 'wait',
    description:
      'Block until a new message addressed to you arrives in a room, then return it. `room` (required) ' +
      'and `me` (your agent name, matching what peers put in `to`). Optional `channel` (default "main"), ' +
      '`after_cursor` (only return messages after this cursor; omit to continue from where you left off), ' +
      '`timeout_seconds` (default 55, max 3600). Returns { reason: "message"|"timeout"|"cancelled", room, ' +
      'messages, next_cursor }. Waiting uses no model turns. IMPORTANT: if reason is "timeout" and you ' +
      'still expect a reply, call wait AGAIN. Keep looping post/wait until the exchange concludes or a ' +
      'peer sends STOP; do not return your final answer and go idle mid-conversation.',
    inputSchema: {
      type: 'object',
      properties: {
        room: { type: 'string', description: 'Room id (required).' },
        me: { type: 'string', description: 'Your agent name (what peers address in `to`).' },
        channel: { type: 'string', description: 'Sub-topic within the room. Default "main".' },
        after_cursor: { type: 'number', description: 'Return messages with cursor greater than this.' },
        timeout_seconds: { type: 'number', description: 'Max seconds to block. Default 55.' },
      },
      required: ['room', 'me'],
    },
  },
  {
    name: 'history',
    description: 'Return a room\'s transcript (every message, regardless of addressee), optionally filtered by `channel`. `room` required. Optional `limit` = most recent N. Use it to catch up when you join.',
    inputSchema: {
      type: 'object',
      properties: {
        room: { type: 'string', description: 'Room id (required).' },
        channel: { type: 'string', description: 'Filter to one channel (optional).' },
        limit: { type: 'number', description: 'Most recent N messages.' },
      },
      required: ['room'],
    },
  },
]

const pendingWaits = new Map() // rpc id -> cancel()

async function handleToolCall(id, params) {
  const name = params?.name
  const a = params?.arguments || {}
  try {
    if (name === 'create_room') {
      result(id, textResult(JSON.stringify(createRoom({ title: a.title, room: a.room }))))
      return
    }
    if (name === 'list_rooms') {
      result(id, textResult(JSON.stringify(listRooms(), null, 2)))
      return
    }
    if (name === 'post') {
      const r = post({ room: a.room, from: a.from, to: a.to, channel: a.channel, message: a.message, reply_to: a.reply_to, title: a.title })
      result(id, textResult(JSON.stringify(r)))
      return
    }
    if (name === 'wait') {
      const room = validId(a.room, 'room')
      const me = validId(a.me ?? '', 'me')
      const channel = a.channel ? validId(a.channel, 'channel') : 'main'
      const secs = Math.max(1, Math.min(Number(a.timeout_seconds) || DEFAULT_WAIT_S, MAX_WAIT_S))
      const after = Number.isFinite(a.after_cursor) ? Math.max(0, Math.floor(a.after_cursor)) : cursorFor(room, channel, me)
      const ctrl = waitForMessages({ room, me, channel, after, timeoutMs: secs * 1000 })
      pendingWaits.set(id, ctrl.cancel)
      let r
      try { r = await ctrl.promise } finally { pendingWaits.delete(id) }
      if (r.reason === 'cancelled') return // client cancelled; it expects no response
      if (r.reason === 'message') setCursor(room, channel, me, r.next_cursor)
      result(id, textResult(JSON.stringify(r)))
      return
    }
    if (name === 'history') {
      const room = validId(a.room, 'room')
      const ch = a.channel ? validId(a.channel, 'channel') : null
      let all = readMessages(room).map(({ id: mid, from, to, channel, ts, reply_to, message, seq }) => ({ message_id: mid, from, to, channel: channel || 'main', ts, reply_to: reply_to ?? null, cursor: seq + 1, message }))
      if (ch) all = all.filter((m) => m.channel === ch)
      const limit = Number(a.limit) > 0 ? Number(a.limit) : all.length
      result(id, textResult(JSON.stringify(all.slice(-limit), null, 2)))
      return
    }
    throw new Error(`unknown tool: ${name}`)
  } catch (e) {
    pendingWaits.delete(id)
    result(id, textResult('ERROR: ' + e.message, true))
  }
}

function handle(id, method, params) {
  switch (method) {
    case 'initialize':
      result(id, {
        protocolVersion: (params && params.protocolVersion) || '2025-06-18',
        capabilities: { tools: {} },
        serverInfo: { name: 'agent-chat', version: '0.4.0' },
        instructions:
          `This server is scoped to project "${SCOPE.project}" (${SCOPE.projectRoot}). ` +
          'Every room operation stays inside that project bucket. ' +
          'Use one room per topic, post under your own agent name, and call wait instead of polling.',
      })
      return
    case 'tools/list':
      result(id, { tools: TOOLS })
      return
    case 'tools/call':
      void handleToolCall(id, params)
      return
    case 'notifications/cancelled': {
      const cancel = pendingWaits.get(params?.requestId)
      if (cancel) { pendingWaits.delete(params.requestId); cancel() }
      return
    }
    case 'ping':
      result(id, {})
      return
    default:
      if (id !== undefined && id !== null) rpcError(id, -32601, `method not found: ${method}`)
  }
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  const s = line.trim()
  if (!s) return
  let msg
  try { msg = JSON.parse(s) } catch { return }
  if (msg.method === undefined) return // a response to us; ignore
  handle(msg.id, msg.method, msg.params)
})
rl.on('close', () => process.exit(0))

const shutdown = () => {
  for (const cancel of pendingWaits.values()) { try { cancel() } catch {} }
  if (heldLock) { try { fs.unlinkSync(heldLock) } catch {} }
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)

process.stderr.write(
  `[agent-chat] ready, project: ${SCOPE.project}, rooms dir: ${ROOMS}\n`,
)
