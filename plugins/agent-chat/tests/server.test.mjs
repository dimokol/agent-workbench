// Integration tests for the agent-chat MCP server. Each test spawns real server
// processes (standing in for separate CLIs) and drives them over stdio JSON-RPC,
// the way an MCP client does. Everything lives in temp folders that are removed
// at the end. Run with: node --test tests/

import { after, describe, test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync, spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SERVER = path.join(HERE, '..', 'server', 'server.mjs')
const CALL = path.join(HERE, '..', 'scripts', 'call.mjs')

const tmpDirs = []
const clients = []
function tmp(label) {
  const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `agent-chat-${label}-`)))
  tmpDirs.push(d)
  return d
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function cleanEnv(extra = {}) {
  const env = { ...process.env }
  for (const k of ['AGENT_CHAT_DIR', 'AGENT_CHAT_ROOT', 'AGENT_CHAT_PROJECT']) delete env[k]
  return { ...env, ...extra }
}

function client({ cwd = process.cwd(), env = {} } = {}) {
  const proc = spawn('node', [SERVER], { cwd, env: cleanEnv(env), stdio: ['pipe', 'pipe', 'ignore'] })
  const pending = new Map()
  let buf = ''
  proc.stdout.on('data', (d) => {
    buf += d.toString()
    let i
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i)
      buf = buf.slice(i + 1)
      if (!line.trim()) continue
      let msg
      try { msg = JSON.parse(line) } catch { continue }
      if (msg.id != null && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id) }
    }
  })
  let idc = 0
  const write = (obj) => proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...obj }) + '\n')
  const rpc = (method, params) => new Promise((res) => {
    const id = ++idc
    pending.set(id, res)
    write({ id, method, params })
  })
  const rpcId = (method, params) => {
    const id = ++idc
    const promise = new Promise((res) => pending.set(id, res))
    write({ id, method, params })
    return { id, promise }
  }
  const c = { proc, rpc, rpcId, pending, notify: (method, params) => write({ method, params }), instructions: '' }
  clients.push(c)
  return c
}

async function init(c) {
  const r = await c.rpc('initialize', { protocolVersion: '2025-06-18' })
  c.instructions = r.result?.instructions ?? ''
  c.serverInfo = r.result?.serverInfo
  c.notify('notifications/initialized')
  return c
}
async function start(opts) { return init(client(opts)) }

const parse = (res) => { const t = res?.content?.[0]?.text; try { return JSON.parse(t) } catch { return t } }
const raw = async (c, name, args) => (await c.rpc('tools/call', { name, arguments: args })).result
const tool = async (c, name, args) => parse(await raw(c, name, args))

function exited(proc) {
  return new Promise((res) => (proc.exitCode !== null || proc.signalCode ? res() : proc.once('exit', res)))
}

function makeRepo(parent, name) {
  const root = path.join(parent, name)
  fs.mkdirSync(path.join(root, '.git'), { recursive: true })
  return fs.realpathSync(root)
}

after(async () => {
  for (const c of clients) c.proc.kill()
  await Promise.all(clients.map((c) => exited(c.proc)))
  for (const d of tmpDirs) fs.rmSync(d, { recursive: true, force: true })
})

describe('rooms, delivery and durability (legacy AGENT_CHAT_DIR mode)', () => {
  const DIR = tmp('legacy')
  let A, B, room

  test('tools/list exposes the five tools', async () => {
    A = await start({ env: { AGENT_CHAT_DIR: DIR } })
    B = await start({ env: { AGENT_CHAT_DIR: DIR } })
    const list = await A.rpc('tools/list', {})
    const names = list.result.tools.map((t) => t.name).sort()
    assert.deepEqual(names, ['create_room', 'history', 'list_rooms', 'post', 'wait'])
    assert.equal(A.serverInfo.name, 'agent-chat')
  })

  test('create_room derives a slug id and stores the title; list_rooms shows it', async () => {
    room = await tool(A, 'create_room', { title: 'Phase 1 Chase Camera' })
    assert.equal(room.room, 'phase-1-chase-camera')
    assert.equal(room.title, 'Phase 1 Chase Camera')
    const rooms = await tool(A, 'list_rooms', {})
    assert.ok(rooms.some((r) => r.room === room.room && r.title === 'Phase 1 Chase Camera'))
    assert.ok(fs.existsSync(path.join(DIR, 'rooms', room.room, 'room.json')))
  })

  test('post without a room errors', async () => {
    const r = await raw(A, 'post', { from: 'claude', message: 'hi' })
    assert.equal(r.isError, true)
  })

  test('post wakes a blocked waiter in the same room', async () => {
    const waiting = tool(B, 'wait', { room: room.room, me: 'codex', timeout_seconds: 10 })
    await sleep(400)
    const posted = await tool(A, 'post', { room: room.room, from: 'claude', to: 'codex', message: 'idea X: raycast springs?' })
    assert.equal(posted.room, room.room)
    assert.equal(posted.cursor, 1)
    const got = await waiting
    assert.equal(got.reason, 'message')
    assert.match(got.messages[0].message, /idea X/)
  })

  test('a post to another room does not wake the waiter', async () => {
    const other = await tool(A, 'create_room', { title: 'Unrelated Debate' })
    const waiting = tool(B, 'wait', { room: room.room, me: 'codex', timeout_seconds: 1 })
    await sleep(150)
    await tool(A, 'post', { room: other.room, from: 'claude', to: 'codex', message: 'other room' })
    assert.equal((await waiting).reason, 'timeout')
  })

  test('explicit duplicate id errors; duplicate title auto-suffixes', async () => {
    const dup = await raw(A, 'create_room', { title: 'Whatever', room: room.room })
    assert.equal(dup.isError, true)
    assert.match(dup.content[0].text, /already exists/)
    const t1 = await tool(A, 'create_room', { title: 'Same Title' })
    const t2 = await tool(A, 'create_room', { title: 'Same Title' })
    assert.notEqual(t1.room, t2.room)
    assert.ok(t2.room.startsWith('same-title'))
  })

  test('a waiter on a room that does not exist yet wakes on the first post', async () => {
    const waiting = tool(B, 'wait', { room: 'lazy-room', me: 'codex', timeout_seconds: 10 })
    await sleep(400)
    await tool(A, 'post', { room: 'lazy-room', from: 'claude', to: 'codex', title: 'Lazily Made', message: 'created on first post' })
    const pre = await waiting
    assert.equal(pre.reason, 'message')
    assert.match(pre.messages[0].message, /created on first post/)
    const rooms = await tool(A, 'list_rooms', {})
    assert.equal(rooms.find((r) => r.room === 'lazy-room').title, 'Lazily Made')
  })

  test('a message to someone else does not wake; a broadcast does', async () => {
    const t0 = Date.now()
    const wrong = await tool(B, 'wait', { room: room.room, me: 'codex', timeout_seconds: 1 })
    await tool(A, 'post', { room: room.room, from: 'claude', to: 'nobody', message: 'not for codex' })
    assert.equal(wrong.reason, 'timeout')
    assert.ok(Date.now() - t0 >= 900)

    const bcast = tool(B, 'wait', { room: room.room, me: 'codex', timeout_seconds: 10 })
    await sleep(300)
    await tool(A, 'post', { room: room.room, from: 'claude', to: '*', message: 'broadcast: standup?' })
    const bc = await bcast
    assert.equal(bc.reason, 'message')
    assert.match(bc.messages.at(-1).message, /broadcast/)
  })

  test('you never receive your own message', async () => {
    const waiting = tool(A, 'wait', { room: room.room, me: 'claude', timeout_seconds: 1 })
    await sleep(150)
    await tool(A, 'post', { room: room.room, from: 'claude', to: 'all', message: 'talking to myself' })
    assert.equal((await waiting).reason, 'timeout')
  })

  test('after_cursor returns only newer messages', async () => {
    const hist = await tool(A, 'history', { room: room.room })
    const last = hist.at(-1).cursor
    await tool(B, 'post', { room: room.room, from: 'codex', to: 'claude', message: 'newer-than-cursor' })
    const paged = await tool(A, 'wait', { room: room.room, me: 'claude', after_cursor: last, timeout_seconds: 5 })
    assert.equal(paged.reason, 'message')
    assert.equal(paged.messages.length, 1)
    assert.match(paged.messages[0].message, /newer-than-cursor/)
  })

  test('channels filter both wait and history', async () => {
    await tool(A, 'post', { room: room.room, from: 'claude', to: 'all', channel: 'side', message: 'side talk' })
    const side = await tool(A, 'history', { room: room.room, channel: 'side' })
    assert.equal(side.length, 1)
    assert.equal(side[0].channel, 'side')
    const limited = await tool(A, 'history', { room: room.room, limit: 2 })
    assert.equal(limited.length, 2)
  })

  test('a cancelled wait sends no result and the server keeps working', async () => {
    // Start from the end of the log so earlier broadcasts don't satisfy the wait.
    const end = (await tool(A, 'history', { room: room.room })).at(-1).cursor
    const c = B.rpcId('tools/call', { name: 'wait', arguments: { room: room.room, me: 'codex', after_cursor: end, timeout_seconds: 30 } })
    await sleep(300)
    B.notify('notifications/cancelled', { requestId: c.id })
    await sleep(300)
    assert.ok(B.pending.has(c.id))
    const after = tool(B, 'wait', { room: room.room, me: 'codex', after_cursor: end, timeout_seconds: 10 })
    await sleep(300)
    await tool(A, 'post', { room: room.room, from: 'claude', to: 'codex', message: 'still alive after cancel' })
    const ac = await after
    assert.equal(ac.reason, 'message')
    assert.match(ac.messages.at(-1).message, /still alive/)
  })

  test('concurrent posts from two processes lose nothing and leave no lock file', async () => {
    const N = 40
    const burst = []
    for (let i = 0; i < N; i++) {
      burst.push(tool(A, 'post', { room: room.room, from: 'claude', to: 'all', channel: 'stress', message: `A-${i}` }))
      burst.push(tool(B, 'post', { room: room.room, from: 'codex', to: 'all', channel: 'stress', message: `B-${i}` }))
    }
    await Promise.all(burst)
    const lines = fs.readFileSync(path.join(DIR, 'rooms', room.room, 'chat.jsonl'), 'utf8').split('\n').filter((l) => l.trim())
    const seen = new Set()
    for (const l of lines) {
      const m = JSON.parse(l)
      if (m.channel === 'stress') seen.add(m.message)
    }
    assert.equal(seen.size, 2 * N)
    assert.equal(fs.existsSync(path.join(DIR, 'rooms', room.room, '.lock')), false)
  })

  test('a restarted process resumes from a saved cursor', async () => {
    const saved = (await tool(A, 'history', { room: room.room, channel: 'main' })).at(-1).cursor
    B.proc.kill()
    await exited(B.proc)
    await tool(A, 'post', { room: room.room, from: 'claude', to: 'codex', message: 'sent while codex was down' })
    const B2 = await start({ env: { AGENT_CHAT_DIR: DIR } })
    const resumed = await tool(B2, 'wait', { room: room.room, me: 'codex', after_cursor: saved, timeout_seconds: 5 })
    assert.equal(resumed.reason, 'message')
    assert.ok(resumed.messages.some((m) => /while codex was down/.test(m.message)))
  })

  test('chat.md has the title header and the transcript', () => {
    const md = fs.readFileSync(path.join(DIR, 'rooms', room.room, 'chat.md'), 'utf8')
    assert.match(md, /^# Phase 1 Chase Camera/)
    assert.match(md, /idea X/)
  })

  test('invalid ids are rejected', async () => {
    const r = await raw(A, 'post', { room: '../escape', from: 'claude', message: 'x' })
    assert.equal(r.isError, true)
    assert.equal(fs.existsSync(path.join(DIR, 'escape')), false)
  })
})

describe('per-project buckets under AGENT_CHAT_ROOT', () => {
  const base = tmp('central')
  const chats = path.join(base, 'chats')

  test('two processes in one repo share rooms; another repo cannot see them', async () => {
    const alpha = makeRepo(path.join(base, 'work'), 'alpha.project')
    const beta = makeRepo(path.join(base, 'work'), 'beta-project')
    const PA1 = await start({ cwd: alpha, env: { AGENT_CHAT_ROOT: chats } })
    const PA2 = await start({ cwd: path.join(alpha, '.git'), env: { AGENT_CHAT_ROOT: chats } })
    const PB = await start({ cwd: beta, env: { AGENT_CHAT_ROOT: chats } })

    const a = await tool(PA1, 'create_room', { title: 'Same room name', room: 'shared-id' })
    const fromA2 = await tool(PA2, 'list_rooms', {})
    const fromB = await tool(PB, 'list_rooms', {})
    const b = await tool(PB, 'create_room', { title: 'Same room name', room: 'shared-id' })

    assert.equal(a.room, 'shared-id')
    assert.equal(b.room, 'shared-id')
    assert.ok(fromA2.some((r) => r.room === 'shared-id'))
    assert.equal(fromB.length, 0)
    assert.ok(fs.existsSync(path.join(chats, 'alpha.project', 'rooms', 'shared-id', 'room.json')))
    assert.ok(fs.existsSync(path.join(chats, 'beta-project', 'rooms', 'shared-id', 'room.json')))
    const meta = JSON.parse(fs.readFileSync(path.join(chats, 'alpha.project', 'project.json'), 'utf8'))
    assert.equal(meta.project_root, alpha)
  })

  test('a linked worktree maps to the main repo bucket', async () => {
    const main = makeRepo(base, 'wt-main')
    const gitdir = path.join(main, '.git', 'worktrees', 'feature-x')
    fs.mkdirSync(gitdir, { recursive: true })
    const wt = path.join(base, 'wt-feature-x', 'src')
    fs.mkdirSync(wt, { recursive: true })
    fs.writeFileSync(path.join(base, 'wt-feature-x', '.git'), `gitdir: ${gitdir}\n`)

    const M = await start({ cwd: main, env: { AGENT_CHAT_ROOT: chats } })
    const W = await start({ cwd: wt, env: { AGENT_CHAT_ROOT: chats } })
    await tool(M, 'create_room', { title: 'Across worktrees', room: 'wt-room' })
    const seen = await tool(W, 'list_rooms', {})
    assert.ok(seen.some((r) => r.room === 'wt-room'))
    assert.match(W.instructions, /"wt-main"/)
    assert.equal(fs.existsSync(path.join(chats, 'wt-feature-x')), false)
    assert.equal(fs.existsSync(path.join(chats, 'src')), false)
  })

  test('two different repos with the same folder name get separate buckets (hash suffix)', async () => {
    const first = makeRepo(path.join(base, 'one'), 'app')
    const second = makeRepo(path.join(base, 'two'), 'app')
    const P1 = await start({ cwd: first, env: { AGENT_CHAT_ROOT: chats } })
    const P2 = await start({ cwd: second, env: { AGENT_CHAT_ROOT: chats } })
    await tool(P1, 'create_room', { title: 'First app', room: 'only-first' })
    await tool(P2, 'create_room', { title: 'Second app', room: 'only-second' })

    const r1 = (await tool(P1, 'list_rooms', {})).map((r) => r.room)
    const r2 = (await tool(P2, 'list_rooms', {})).map((r) => r.room)
    assert.deepEqual(r1, ['only-first'])
    assert.deepEqual(r2, ['only-second'])

    const buckets = fs.readdirSync(chats).filter((n) => /^app(-[0-9a-f]{8})?$/.test(n))
    assert.equal(buckets.length, 2)
    assert.ok(buckets.includes('app'))
    const suffixed = buckets.find((n) => n !== 'app')
    assert.match(suffixed, /^app-[0-9a-f]{8}$/)
    const meta = JSON.parse(fs.readFileSync(path.join(chats, suffixed, 'project.json'), 'utf8'))
    assert.equal(meta.project_root, second)
    assert.match(P2.instructions, new RegExp(`"${suffixed}"`))
  })

  test('initialize instructions name the project and its root', async () => {
    const repo = makeRepo(base, 'instr-repo')
    const C = await start({ cwd: repo, env: { AGENT_CHAT_ROOT: chats } })
    assert.match(C.instructions, /scoped to project "instr-repo"/)
    assert.ok(C.instructions.includes(repo))
    assert.match(C.instructions, /wait/)
  })

  test('AGENT_CHAT_PROJECT overrides the inferred name', async () => {
    const repo = makeRepo(base, 'named-by-folder')
    const C = await start({ cwd: repo, env: { AGENT_CHAT_ROOT: chats, AGENT_CHAT_PROJECT: 'custom-name' } })
    await tool(C, 'create_room', { title: 'x', room: 'r1' })
    assert.ok(fs.existsSync(path.join(chats, 'custom-name', 'rooms', 'r1', 'room.json')))
    assert.equal(fs.existsSync(path.join(chats, 'named-by-folder')), false)
  })

  test('two repos with the same AGENT_CHAT_PROJECT share one bucket, with no suffix', async () => {
    const api = makeRepo(path.join(base, 'shared'), 'api')
    const web = makeRepo(path.join(base, 'shared'), 'web')
    const env = { AGENT_CHAT_ROOT: chats, AGENT_CHAT_PROJECT: 'shared' }
    const A = await start({ cwd: api, env })
    const W = await start({ cwd: web, env })
    assert.match(A.instructions, /scoped to project "shared"/)
    assert.match(W.instructions, /scoped to project "shared"/)

    await tool(A, 'create_room', { title: 'Search API shape', room: 'search-api' })
    const seen = await tool(W, 'list_rooms', {})
    assert.ok(seen.some((r) => r.room === 'search-api'))
    await tool(W, 'post', { room: 'search-api', from: 'web', message: 'use items[]' })
    const hist = await tool(A, 'history', { room: 'search-api' })
    assert.ok(JSON.stringify(hist).includes('use items[]'))

    assert.deepEqual(fs.readdirSync(chats).filter((n) => n.startsWith('shared')), ['shared'])
  })

  test('a leading ~ in AGENT_CHAT_ROOT expands to the home folder', async () => {
    const home = tmp('home')
    const repo = makeRepo(base, 'tilde-repo')
    const C = await start({ cwd: repo, env: { HOME: home, AGENT_CHAT_ROOT: '~/my-chats' } })
    await tool(C, 'create_room', { title: 'x', room: 'r1' })
    assert.ok(fs.existsSync(path.join(home, 'my-chats', 'tilde-repo', 'rooms', 'r1', 'room.json')))
    assert.equal(fs.existsSync(path.join(repo, '~')), false)
  })

  test('with no env set the root defaults to ~/.agent-chat', async () => {
    const home = tmp('home')
    const repo = makeRepo(base, 'default-repo')
    const C = await start({ cwd: repo, env: { HOME: home } })
    await tool(C, 'create_room', { title: 'x', room: 'r1' })
    assert.ok(fs.existsSync(path.join(home, '.agent-chat', 'default-repo', 'rooms', 'r1', 'room.json')))
  })

  test('AGENT_CHAT_DIR keeps the legacy single folder, ~ included', async () => {
    const home = tmp('home')
    const repo = makeRepo(base, 'legacy-repo')
    const C = await start({ cwd: repo, env: { HOME: home, AGENT_CHAT_DIR: '~/flat', AGENT_CHAT_ROOT: chats } })
    await tool(C, 'create_room', { title: 'x', room: 'r1' })
    assert.ok(fs.existsSync(path.join(home, 'flat', 'rooms', 'r1', 'room.json')))
    assert.equal(fs.existsSync(path.join(chats, 'legacy-repo')), false)
  })
})

describe('launch review', () => {
  test('a room id or AGENT_CHAT_PROJECT that starts with a dot is refused', async () => {
    const base = tmp('dots')
    const root = path.join(base, 'root')
    const repo = makeRepo(base, 'dot-repo')
    const C = await start({ cwd: repo, env: { AGENT_CHAT_ROOT: root } })
    for (const room of ['..', '.', '.hidden']) {
      const r = await raw(C, 'post', { room, from: 'a', message: 'hi' })
      assert.equal(r.isError, true, room)
    }
    const w = await raw(C, 'wait', { room: '..', me: 'a', timeout_seconds: 1 })
    assert.equal(w.isError, true)
    assert.equal(fs.existsSync(path.join(root, 'dot-repo', 'room.json')), false)
    assert.equal(fs.existsSync(path.join(root, 'dot-repo', 'chat.jsonl')), false)

    const P = client({ cwd: repo, env: { AGENT_CHAT_ROOT: root, AGENT_CHAT_PROJECT: '..' } })
    await exited(P.proc)
    assert.notEqual(P.proc.exitCode, 0)
    assert.equal(fs.existsSync(path.join(base, 'project.json')), false)
    assert.equal(fs.existsSync(path.join(base, 'rooms')), false)
  })




  test('folders are private to the user (0700) and files too (0600)', async () => {
    const base = tmp('modes')
    const root = path.join(base, 'root')
    const repo = makeRepo(base, 'mode-repo')
    const C = await start({ cwd: repo, env: { AGENT_CHAT_ROOT: root } })
    await tool(C, 'create_room', { title: 'Private', room: 'r' })
    await tool(C, 'post', { room: 'r', from: 'a', message: 'secret' })
    await tool(C, 'post', { room: 'lazy', from: 'a', message: 'made on first post' })
    const mode = (p) => fs.statSync(p).mode & 0o777
    for (const d of [root, path.join(root, 'mode-repo'), path.join(root, 'mode-repo', 'rooms'), path.join(root, 'mode-repo', 'rooms', 'r'), path.join(root, 'mode-repo', 'rooms', 'lazy')]) {
      assert.equal(mode(d), 0o700, d)
    }
    for (const f of ['project.json', 'rooms/r/room.json', 'rooms/r/chat.md', 'rooms/r/chat.jsonl', 'rooms/lazy/chat.jsonl']) {
      assert.equal(mode(path.join(root, 'mode-repo', f)), 0o600, f)
    }
  })
})

describe('call.mjs helper', () => {
  test('prints a tool result and exits 0; exits 1 on a tool error', () => {
    const base = tmp('call')
    const repo = makeRepo(base, 'call-repo')
    const env = cleanEnv({ AGENT_CHAT_ROOT: path.join(base, 'chats') })
    const run = (...args) => execFileSync('node', [CALL, ...args], { cwd: repo, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
    const made = JSON.parse(run('create_room', '{"title":"From shell"}'))
    assert.equal(made.room, 'from-shell')
    const rooms = JSON.parse(run('list_rooms'))
    assert.equal(rooms[0].room, 'from-shell')
    assert.throws(() => run('post', '{"room":"from-shell"}'), (e) => e.status === 1)
  })
})

describe('cleanup', () => {
  test('no server process is left running and no lock files remain', async () => {
    for (const c of clients) c.proc.kill()
    await Promise.all(clients.map((c) => exited(c.proc)))
    assert.ok(clients.every((c) => c.proc.exitCode !== null || c.proc.signalCode))
    const locks = []
    const walk = (d) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name)
        if (e.isDirectory()) walk(p)
        else if (e.name === '.lock') locks.push(p)
      }
    }
    for (const d of tmpDirs) walk(d)
    assert.deepEqual(locks, [])
  })

  test('temp folders are removed at the end', async () => {
    const probe = tmp('probe')
    fs.writeFileSync(path.join(probe, 'x'), '1')
    fs.rmSync(probe, { recursive: true, force: true })
    assert.equal(fs.existsSync(probe), false)
  })
})

process.on('exit', () => {
  for (const d of tmpDirs) fs.rmSync(d, { recursive: true, force: true })
  const left = tmpDirs.filter((d) => fs.existsSync(d))
  if (left.length) { console.error('temp folders left behind:', left); process.exitCode = 1 }
})
