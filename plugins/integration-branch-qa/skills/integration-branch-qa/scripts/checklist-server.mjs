#!/usr/bin/env node
// node checklist-server.mjs [file] [--port N]: a clickable page for a markdown
// checklist on 127.0.0.1 (port 4777, or the next free one). Each tick is written
// into the file, which stays the one source of truth. No dependencies.

import { readFileSync, realpathSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { basename, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const CHECKBOX = /^(\s*[-*] \[)([ xX])(\](?:\s.*)?)$/;

export function splitLines(text) {
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  return { eol, lines: text.split(eol) };
}

// Sections start at "## " headings. Fenced code is skipped, and boxes above
// the first section are left out of the counts.
export function parseChecklist(text) {
  const sections = [];
  let current = null;
  let fence = false;
  splitLines(text).lines.forEach((line, i) => {
    if (/^\s*```/.test(line)) { fence = !fence; return; }
    if (fence) return;
    const h = line.match(/^(#{1,2}) (.*)$/);
    if (h) {
      current = h[1] === '##' ? { title: h[2].trim(), line: i, items: [] } : null;
      if (current) sections.push(current);
      return;
    }
    const m = line.match(CHECKBOX);
    if (m && current) current.items.push({ line: i, checked: m[2] !== ' ', text: m[3].slice(1).trim() });
  });
  return sections.map((s) => ({ ...s, done: s.items.filter((x) => x.checked).length, total: s.items.length }));
}

// Flip one box, but only if that line still reads what the page saw: someone
// may have edited the file since the page last loaded.
export function toggleLine(text, { line, expected, checked }) {
  const { eol, lines } = splitLines(text);
  if (!Number.isInteger(line) || lines[line] !== expected || !CHECKBOX.test(expected)) {
    return { ok: false, error: 'The file changed since the page loaded. Reloaded; try again.' };
  }
  lines[line] = expected.replace(CHECKBOX, (_, a, _m, c) => `${a}${checked ? 'x' : ' '}${c}`);
  return { ok: true, text: lines.join(eol) };
}

export function writeToggle(file, change) {
  const result = toggleLine(readFileSync(file, 'utf8'), change);
  if (!result.ok) return result;
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, result.text);
  renameSync(tmp, file); // atomic: readers never see half a file
  return { ok: true };
}

const send = (res, status, type, body) => {
  res.writeHead(status, { 'Cache-Control': 'no-store', 'Content-Type': type });
  res.end(body);
};
const json = (res, status, body) => send(res, status, 'application/json', JSON.stringify(body));

export function createChecklistServer(file) {
  return createServer((req, res) => {
    // Only localhost names: a page on another site can't reach this through DNS rebinding.
    const host = String(req.headers.host ?? '').replace(/:\d+$/, '');
    if (host !== 'localhost' && host !== '127.0.0.1') return send(res, 403, 'text/plain', 'forbidden');
    const { pathname } = new URL(req.url, 'http://localhost');
    if (req.method === 'GET' && pathname === '/') return send(res, 200, 'text/html; charset=utf-8', PAGE);
    if (req.method === 'GET' && pathname === '/api') {
      try {
        const text = readFileSync(file, 'utf8');
        return json(res, 200, { file: basename(file), lines: splitLines(text).lines, mtime: statSync(file).mtimeMs, sections: parseChecklist(text) });
      } catch (e) {
        return json(res, 500, { error: String(e.message) });
      }
    }
    if (req.method === 'POST' && pathname === '/toggle') {
      // A JSON content type forces a CORS preflight, which this server never answers.
      if (!String(req.headers['content-type'] ?? '').startsWith('application/json')) {
        return json(res, 415, { error: 'Send JSON.', ok: false });
      }
      let body = '';
      req.on('data', (c) => { body += c; if (body.length > 65536) req.destroy(); });
      req.on('end', () => {
        try {
          const { line, text, checked } = JSON.parse(body);
          json(res, 200, writeToggle(file, { checked: Boolean(checked), expected: text, line }));
        } catch (e) {
          json(res, 400, { error: String(e.message), ok: false });
        }
      });
      return;
    }
    send(res, 404, 'text/plain', 'not found');
  });
}

// Port taken: try the next one up, at most 20 times.
function listen(server, port, triesLeft) {
  const onError = (err) => {
    if (err.code !== 'EADDRINUSE' || triesLeft <= 0) {
      console.error(`Could not listen: ${err.message}`);
      process.exit(1);
    }
    console.log(`Port ${port} is taken; trying ${port + 1}.`);
    listen(server, port + 1, triesLeft - 1);
  };
  server.once('error', onError);
  server.once('listening', () => server.off('error', onError));
  server.listen(port, '127.0.0.1');
}

function main(args) {
  const flag = args.indexOf('--port');
  const port = Number(flag === -1 ? 4777 : args[flag + 1]);
  const file = resolve(args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--port') ?? '.qa/checklist.md');
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error('--port needs a number from 1 to 65535.');
    process.exit(1);
  }
  try {
    statSync(file);
  } catch {
    console.error(`No checklist at ${file}. Run qa-branch.sh init first, or pass the file.`);
    process.exit(1);
  }
  const server = createChecklistServer(file);
  server.on('listening', () => console.log(`Checklist: http://localhost:${server.address().port}  (${file}). Ctrl+C stops it.`));
  listen(server, port, 20);
}

const PAGE = String.raw`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>QA checklist</title>
<style>
:root{--bg:#fafaf9;--fg:#1c1917;--muted:#78716c;--card:#fff;--line:#e7e5e4;--accent:#2563eb;--done:#a8a29e;--code:#f5f5f4;--ok:#16a34a}
@media (prefers-color-scheme:dark){:root{--bg:#1c1917;--fg:#e7e5e4;--muted:#a8a29e;--card:#262322;--line:#3a3532;--accent:#60a5fa;--done:#78716c;--code:#302b29;--ok:#4ade80}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:16px 16px 80px}
header{position:sticky;top:0;background:var(--bg);padding:10px 0;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;gap:12px;z-index:1}
header span,.count{color:var(--muted);font-size:13px;white-space:nowrap}.count.all{color:var(--ok);font-weight:600}
h1{font-size:21px;margin:18px 0 8px}h2{font-size:17px;margin:0}h3{font-size:15px;margin:12px 0 4px}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:12px 0}
.head{display:flex;justify-content:space-between;gap:12px;align-items:baseline;margin-bottom:6px}
label{display:flex;gap:10px;align-items:flex-start;padding:6px 4px;border-radius:6px;cursor:pointer}
label:hover{background:var(--code)}label input{margin-top:4px;width:18px;height:18px;flex:none;accent-color:var(--accent)}
label.on .t{color:var(--done);text-decoration:line-through}
p,li{margin:6px 0}ul{padding-left:22px}code{background:var(--code);padding:1px 5px;border-radius:4px;font-size:13px}
pre{background:var(--code);padding:8px;border-radius:6px;overflow-x:auto}a{color:var(--accent)}
#toast{position:fixed;bottom:16px;left:50%;transform:translateX(-50%);background:var(--fg);color:var(--bg);padding:8px 14px;border-radius:8px;display:none}
</style></head><body><main><header><b>QA checklist</b><span id="meta"></span></header><div id="doc"></div></main><div id="toast"></div>
<script>
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const inline = (s) => esc(s)
  .replace(/\x60([^\x60]+)\x60/g, '<code>$1</code>')
  .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
const BOX = /^(\s*)[-*] \[([ xX])\](?:\s(.*))?$/;
let state = null;

function render({ file, lines, sections }) {
  const done = sections.reduce((n, s) => n + s.done, 0), total = sections.reduce((n, s) => n + s.total, 0);
  document.getElementById('meta').textContent = file + '  ' + done + '/' + total + ' ticked';
  const counts = new Map(sections.map((s) => [s.line, s]));
  const out = [];
  let open = false, list = false, fence = false;
  const endList = () => { if (list) { out.push('</ul>'); list = false; } };
  lines.forEach((raw, i) => {
    const line = raw.replace(/\s+$/, '');
    if (/^\s*\x60\x60\x60/.test(line)) { endList(); fence = !fence; out.push(fence ? '<pre><code>' : '</code></pre>'); return; }
    if (fence) { out.push(esc(raw) + '\n'); return; }
    let m = line.match(/^(#{1,6}) (.*)$/);
    if (m) {
      endList();
      if (m[1].length <= 2 && open) { out.push('</section>'); open = false; }
      const s = counts.get(i);
      if (s) {
        out.push('<section><div class="head"><h2>' + inline(m[2]) + '</h2><span class="count' + (s.total && s.done === s.total ? ' all' : '') + '">' + (s.total ? s.done + '/' + s.total : '') + '</span></div>');
        open = true;
      } else out.push(m[1].length === 1 ? '<h1>' + inline(m[2]) + '</h1>' : '<h3>' + inline(m[2]) + '</h3>');
      return;
    }
    if ((m = line.match(BOX))) {
      endList();
      const on = m[2] !== ' ';
      out.push('<label class="' + (on ? 'on' : '') + '" style="margin-left:' + m[1].length * 8 + 'px"><input type="checkbox" data-line="' + i + '"' + (on ? ' checked' : '') + '><span class="t">' + inline(m[3] || '') + '</span></label>');
      return;
    }
    if ((m = line.match(/^\s*[-*] (.*)$/))) { if (!list) { out.push('<ul>'); list = true; } out.push('<li>' + inline(m[1]) + '</li>'); return; }
    endList();
    if (line.trim() && !/^---+$/.test(line)) out.push('<p>' + inline(line.trim()) + '</p>');
  });
  endList();
  if (open) out.push('</section>');
  const y = window.scrollY;
  document.getElementById('doc').innerHTML = out.join('');
  window.scrollTo(0, y);
}

function toast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.style.display = 'block';
  clearTimeout(t.timer); t.timer = setTimeout(() => (t.style.display = 'none'), 3000);
}

async function load() {
  const data = await (await fetch('/api')).json();
  if (data.error) return toast(data.error);
  if (!state || data.mtime !== state.mtime) { state = data; render(data); }
}

document.addEventListener('change', async (e) => {
  const box = e.target.closest('input[data-line]');
  if (!box) return;
  const line = Number(box.dataset.line);
  const r = await fetch('/toggle', { body: JSON.stringify({ checked: box.checked, line, text: state.lines[line] }), headers: { 'Content-Type': 'application/json' }, method: 'POST' });
  const res = await r.json();
  if (!res.ok) toast(res.error || 'Could not save.');
  state = null;
  await load();
});

load();
setInterval(() => { if (!document.hidden) load().catch(() => toast('The checklist server stopped.')); }, 3000);
</script></body></html>`;

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) main(process.argv.slice(2));
