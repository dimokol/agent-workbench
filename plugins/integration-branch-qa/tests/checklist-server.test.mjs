// Tests for skills/integration-branch-qa/scripts/checklist-server.mjs. Run: node --test tests/checklist-server.test.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { createChecklistServer, parseChecklist, toggleLine, writeToggle } from '../skills/integration-branch-qa/scripts/checklist-server.mjs';

const dir = mkdtempSync(join(tmpdir(), 'qa-checklist-'));
after(() => rmSync(dir, { force: true, recursive: true }));

const SAMPLE = [
  '# QA checklist',
  '',
  '- [ ] a box above the first section',
  '',
  '## #12: sign-up form',
  '',
  '- [ ] Submit an empty form: each field shows its error',
  '- [x] Submit a valid form: you land on the welcome page',
  '### details',
  '  * [X] nested and starred',
  '```',
  '- [ ] inside a code fence',
  '```',
  '',
  '## #13: empty section',
  '',
].join('\n');

test('parseChecklist counts boxes per section', () => {
  const sections = parseChecklist(SAMPLE);
  assert.deepEqual(sections.map((s) => [s.title, s.done, s.total]), [
    ['#12: sign-up form', 2, 3],
    ['#13: empty section', 0, 0],
  ]);
  assert.equal(sections[0].line, 4);
  assert.deepEqual(sections[0].items[0], { checked: false, line: 6, text: 'Submit an empty form: each field shows its error' });
});

test('parseChecklist accepts a box with no text', () => {
  const [s] = parseChecklist('## #1: x\n- [ ]\n- [x]\n');
  assert.equal(s.total, 2);
  assert.equal(s.done, 1);
});

test('toggleLine ticks and unticks the exact line', () => {
  const lines = SAMPLE.split('\n');
  const ticked = toggleLine(SAMPLE, { checked: true, expected: lines[6], line: 6 });
  assert.equal(ticked.ok, true);
  assert.equal(ticked.text.split('\n')[6], '- [x] Submit an empty form: each field shows its error');
  assert.equal(ticked.text.split('\n').filter((l, i) => i !== 6).join('\n'), lines.filter((l, i) => i !== 6).join('\n'));
  const unticked = toggleLine(ticked.text, { checked: false, expected: ticked.text.split('\n')[7], line: 7 });
  assert.equal(unticked.text.split('\n')[7], '- [ ] Submit a valid form: you land on the welcome page');
});

test('toggleLine refuses when the line changed or is not a box', () => {
  assert.equal(toggleLine(SAMPLE, { checked: true, expected: '- [ ] something else', line: 6 }).ok, false);
  assert.equal(toggleLine(SAMPLE, { checked: true, expected: '## #12: sign-up form', line: 4 }).ok, false);
  assert.equal(toggleLine(SAMPLE, { checked: true, expected: undefined, line: 99 }).ok, false);
  assert.equal(toggleLine(SAMPLE, { checked: true, expected: '- [ ] a box above the first section', line: '2' }).ok, false);
});

test('toggleLine keeps CRLF line endings and the final newline', () => {
  const text = '## #1: x\r\n- [ ] one\r\n- [ ] two\r\n';
  const result = toggleLine(text, { checked: true, expected: '- [ ] two', line: 2 });
  assert.equal(result.text, '## #1: x\r\n- [ ] one\r\n- [x] two\r\n');
});

test('writeToggle writes the change back to the file', () => {
  const file = join(dir, 'write.md');
  writeFileSync(file, SAMPLE);
  assert.deepEqual(writeToggle(file, { checked: true, expected: SAMPLE.split('\n')[6], line: 6 }), { ok: true });
  assert.equal(readFileSync(file, 'utf8').split('\n')[6], '- [x] Submit an empty form: each field shows its error');
  assert.equal(writeToggle(file, { checked: true, expected: SAMPLE.split('\n')[6], line: 6 }).ok, false);
});

function call(port, method, path, { body, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const req = request({ headers, host: '127.0.0.1', method, path, port }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => resolve({ body: data, status: res.statusCode }));
    });
    req.on('error', reject);
    req.end(body);
  });
}

test('the server serves the checklist and saves ticks', async (t) => {
  const file = join(dir, 'server.md');
  writeFileSync(file, SAMPLE);
  const server = createChecklistServer(file);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  t.after(() => server.close());
  const { port } = server.address();

  const api = await call(port, 'GET', '/api');
  assert.equal(api.status, 200);
  const data = JSON.parse(api.body);
  assert.equal(data.file, 'server.md');
  assert.equal(data.sections[0].done, 2);
  assert.equal((await call(port, 'GET', '/')).status, 200);

  const json = { 'Content-Type': 'application/json' };
  const body = JSON.stringify({ checked: true, line: 6, text: data.lines[6] });
  const saved = await call(port, 'POST', '/toggle', { body, headers: json });
  assert.deepEqual(JSON.parse(saved.body), { ok: true });
  assert.equal(parseChecklist(readFileSync(file, 'utf8'))[0].done, 3);

  const plain = await call(port, 'POST', '/toggle', { body, headers: { 'Content-Type': 'text/plain' } });
  assert.equal(plain.status, 415);
  const foreign = await call(port, 'GET', '/api', { headers: { Host: 'evil.example.com' } });
  assert.equal(foreign.status, 403);
  const broken = await call(port, 'POST', '/toggle', { body: '{nope', headers: json });
  assert.equal(broken.status, 400);
});
