#!/usr/bin/env node
// One-shot shell client for the agent-chat server: call a single tool and print
// the result. Handy for reading a room from a script, or for an agent whose MCP
// connection has not picked up the server yet.
//
// Usage:
//   node call.mjs list_rooms '{}'
//   node call.mjs history '{"room":"release-plan","limit":20}'
//
// It starts its own server process in the current directory, so it sees the same
// project bucket as an agent started there. AGENT_CHAT_ROOT / AGENT_CHAT_DIR /
// AGENT_CHAT_PROJECT are passed through.

import { spawn } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const server = path.join(here, '..', 'server', 'server.mjs')
const [toolName, rawArgs = '{}'] = process.argv.slice(2)

if (!toolName) {
  process.stderr.write('usage: node call.mjs <tool-name> [json-arguments]\n')
  process.exit(2)
}

let args
try {
  args = JSON.parse(rawArgs)
} catch (error) {
  process.stderr.write(`invalid JSON arguments: ${error.message}\n`)
  process.exit(2)
}

const child = spawn(process.execPath, [server], {
  cwd: process.cwd(),
  env: process.env,
  stdio: ['pipe', 'pipe', 'inherit'],
})

let buffer = ''
let initialized = false
let finished = false

function send(id, method, params) {
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
}

function finish(code) {
  if (finished) return
  finished = true
  child.kill()
  process.exit(code)
}

child.stdout.on('data', (chunk) => {
  buffer += chunk.toString()
  let newline
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline)
    buffer = buffer.slice(newline + 1)
    if (!line.trim()) continue
    let message
    try { message = JSON.parse(line) } catch { continue }
    if (message.id === 1 && !initialized) {
      initialized = true
      child.stdin.write(JSON.stringify({
        jsonrpc: '2.0',
        method: 'notifications/initialized',
      }) + '\n')
      send(2, 'tools/call', { name: toolName, arguments: args })
      continue
    }
    if (message.id === 2) {
      const result = message.result
      const content = result?.content?.[0]?.text
      process.stdout.write((content ?? JSON.stringify(result, null, 2)) + '\n')
      finish(result?.isError ? 1 : 0)
    }
  }
})

child.on('error', (error) => {
  process.stderr.write(`${error.message}\n`)
  finish(1)
})

child.on('exit', (code) => {
  if (!finished) process.exit(code ?? 1)
})

send(1, 'initialize', { protocolVersion: '2025-06-18' })
