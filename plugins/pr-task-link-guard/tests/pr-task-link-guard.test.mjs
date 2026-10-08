// Run from the plugin folder: node --test tests/*.test.mjs
// Commands below are only strings fed to the hook. Nothing here runs them, and
// the only git calls create throwaway repos under the OS temp dir.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { decide, loadConfig, respond } from '../hooks/pr-task-link-guard.mjs';

const root = mkdtempSync(join(tmpdir(), 'pr-task-link-guard-'));
after(() => rmSync(root, { recursive: true, force: true }));

const work = join(root, 'work');
mkdirSync(join(work, 'sub'), { recursive: true });
execFileSync('git', ['init', '-q', work]);
execFileSync('git', ['-C', work, 'remote', 'add', 'origin', 'git@github.com:acme/web.git']);
writeFileSync(join(work, 'linked.md'), 'Fixes the header.\n\nTask: https://tasks.example.com/t/42\n');
writeFileSync(join(work, 'bare.md'), 'Fixes the header.\n');
writeFileSync(join(work, 'sub', 'linked.md'), 'Task: https://tasks.example.com/t/7\n');

const PATTERN = 'tasks\\.example\\.com/t/\\d+';
const env = { PR_TASK_LINK_GUARD_TASK_LINK_PATTERN: PATTERN };
const run = (command, { cwd = work, extra = {} } = {}) => decide({ session_id: 's', cwd, tool_input: { command } }, { ...env, ...extra });
const denies = (cmd, opts) => test(`denies ${JSON.stringify(cmd)}`, () => assert.ok(run(cmd, opts)?.deny, 'expected a deny'));
const allows = (cmd, opts) => test(`allows ${JSON.stringify(cmd)}`, () => assert.equal(run(cmd, opts), null));

for (const cmd of [
  'gh pr create --title x --body "no task here"',
  'gh pr create --fill',
  'gh pr create --title x --body-file bare.md',
  'gh pr create --title x --body-file missing.md',
  'gh pr create --title x --body-file $DIR/linked.md',
  "bash -c 'gh pr create --title x --body none'",
  'git push -u origin feat/x && gh pr create --title x --body none',
  'echo PR_TASK_LINK_GUARD_ALLOW=1 && gh pr create --title x --body none',
  'gh pr --repo acme/web create --title x --body none',
  // Review round 1: shell options and `--`, the shared wrapper list, and gh's `pr new` alias.
  'bash -c -- "gh pr create --title x --body none"',
  "bash -euo pipefail -c 'gh pr create --title x --body none'",
  'timeout 60 gh pr create --title x --body none',
  'sudo gh pr create --title x --body none',
  'nice -n 5 gh pr create --title x --body none',
  'echo x | xargs gh pr create --title x --body',
  'caffeinate -i gh pr create --title x --body none',
  'gh pr new --title x --body none',
]) denies(cmd);

for (const cmd of [
  'gh pr create --title x --body "Task: https://tasks.example.com/t/42"',
  'gh pr create --title x --body "TASK: HTTPS://TASKS.EXAMPLE.COM/T/42"',
  'gh pr create --title x --body-file linked.md',
  'gh pr create --title x --body-file=linked.md',
  'gh pr create --title x -F linked.md',
  `gh pr create --title x --body-file ${join(work, 'linked.md')}`,
  'cd sub && gh pr create --title x --body-file linked.md',
  // The heredoc writes the body file in the same command, so the file isn't there yet.
  "cat > fresh.md <<'EOF'\nTask: https://tasks.example.com/t/9\nEOF\ngh pr create --title x --body-file fresh.md",
  'gh pr create --title x --body "$(cat <<\'EOF\'\n## Summary\nIt\'s done.\n\nTask: https://tasks.example.com/t/5\nEOF\n)"',
  'PR_TASK_LINK_GUARD_ALLOW=1 gh pr create --title x --body none',
  'git push -u origin HEAD && PR_TASK_LINK_GUARD_ALLOW=1 gh pr create --title x --body none',
  'gh pr new --title x --body "Task: https://tasks.example.com/t/1"',
  'gh pr create --web',
  'gh pr view 12',
  'gh pr edit 12 --body none',
  'echo "gh pr create --body none"',
  'git commit -m "gh pr create later"',
]) allows(cmd);

test('a relative --body-file is read from the session cwd, not the hook process cwd', () => {
  assert.notEqual(process.cwd(), work);
  assert.equal(run('gh pr create --title x --body-file linked.md'), null);
  assert.ok(run('gh pr create --title x --body-file linked.md', { cwd: root })?.deny);
});

test('repo_scope limits the check to matching repos', () => {
  const scoped = (cmd, scope, cwd = work) => run(cmd, { cwd, extra: { PR_TASK_LINK_GUARD_REPO_SCOPE: scope } });
  const bare = 'gh pr create --title x --body none';
  assert.ok(scoped(bare, '^acme/')?.deny, 'origin is acme/web');
  assert.equal(scoped(bare, '^other/'), null);
  assert.ok(scoped(`${bare} --repo acme/api`, '^acme/')?.deny);
  assert.ok(scoped(`${bare} -R github.com/acme/api`, '^acme/')?.deny);
  assert.equal(scoped(`${bare} --repo other/api`, '^acme/'), null);
  assert.ok(scoped(`GH_REPO=acme/api ${bare}`, '^acme/', root)?.deny);
  assert.equal(scoped(bare, '^acme/', root), null, 'not a repo and no --repo: out of scope');
});

test('without a pattern it does nothing and says so', () => {
  const r = decide({ cwd: work, tool_input: { command: 'gh pr create --title x --body none' } }, {});
  assert.equal(r.deny, undefined);
  assert.match(r.message, /no task_link_pattern/);
  assert.equal(decide({ cwd: work, tool_input: { command: 'gh pr view 1' } }, {}), null);
});

test('a broken regex lets the PR through and says so', () => {
  const r = run('gh pr create --body none', { extra: { PR_TASK_LINK_GUARD_TASK_LINK_PATTERN: '(' } });
  assert.equal(r.deny, undefined);
  assert.match(r.message, /can't use its config/);
});

test('config: plugin option wins, empty falls through to the env var', () => {
  assert.deepEqual(loadConfig({}), { pattern: '', scope: '' });
  assert.equal(loadConfig({ CLAUDE_PLUGIN_OPTION_TASK_LINK_PATTERN: 'a', PR_TASK_LINK_GUARD_TASK_LINK_PATTERN: 'b' }).pattern, 'a');
  assert.equal(loadConfig({ CLAUDE_PLUGIN_OPTION_TASK_LINK_PATTERN: '', PR_TASK_LINK_GUARD_TASK_LINK_PATTERN: 'b' }).pattern, 'b');
  assert.equal(loadConfig({ CLAUDE_PLUGIN_OPTION_REPO_SCOPE: '^acme/' }).scope, '^acme/');
});

test('the deny reason names the pattern and the way forward', () => {
  const { deny } = run('gh pr create --body none');
  assert.match(deny, /pr-task-link-guard blocked gh pr create/);
  assert.ok(deny.includes(PATTERN));
  assert.match(deny, /PR_TASK_LINK_GUARD_ALLOW=1 directly before gh pr create, not before cd/);
});

test('an internal error lets the PR through with a note once per session', () => {
  const extra = { CLAUDE_PLUGIN_DATA: join(root, 'state-error') };
  const broken = (session) => ({ session_id: session, get tool_input() { throw new Error('boom'); } });
  assert.match(respond(broken('e1'), extra).systemMessage, /internal error: boom/);
  assert.equal(respond(broken('e1'), extra), null);
  assert.ok(respond(broken('e2'), extra).systemMessage);
});

// The launcher, end to end.
const launcher = join(dirname(fileURLToPath(import.meta.url)), '..', 'hooks', 'pr-task-link-guard.sh');
const cleanEnv = Object.fromEntries(
  Object.entries(process.env).filter(([k]) => !/^(CLAUDE_PLUGIN_OPTION_|PR_TASK_LINK_GUARD_)/.test(k)),
);
function hook(command, { session = 's1', extra = {}, input } = {}) {
  const payload = input ?? JSON.stringify({ session_id: session, cwd: work, tool_name: 'Bash', tool_input: { command } });
  return execFileSync('/bin/sh', [launcher], { input: payload, env: { ...cleanEnv, ...extra } }).toString();
}

test('launcher: denies with PreToolUse JSON and stays silent on allow', () => {
  const out = JSON.parse(hook('gh pr create --body none', { extra: env }));
  assert.equal(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.equal(out.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal(hook('gh pr create --body-file linked.md', { extra: env }), '');
  assert.equal(hook('', { input: 'not json' }), '');
});

test('launcher: the missing-pattern note shows once per session', () => {
  const extra = { CLAUDE_PLUGIN_DATA: join(root, 'state-pattern') };
  assert.match(hook('gh pr create --body none', { session: 'p1', extra }), /no task_link_pattern/);
  assert.equal(hook('gh pr create --body none', { session: 'p1', extra }), '');
  assert.match(hook('gh pr create --body none', { session: 'p2', extra }), /no task_link_pattern/);
});

test('launcher: without node it allows and says so once per session', () => {
  const bin = join(root, 'bin-no-node');
  mkdirSync(bin);
  for (const tool of ['cat', 'sed', 'mkdir']) {
    const found = process.env.PATH.split(delimiter).map((d) => join(d, tool)).find((p) => existsSync(p));
    symlinkSync(found, join(bin, tool));
  }
  const extra = { ...env, PATH: bin, CLAUDE_PLUGIN_DATA: join(root, 'state-node') };
  assert.equal(hook('git status', { session: 'n1', extra }), '');
  assert.match(JSON.parse(hook('gh pr create --body none', { session: 'n1', extra })).systemMessage, /node is not on PATH/);
  assert.equal(hook('gh pr create --body none', { session: 'n1', extra }), '');
});

test('launcher: a node that fails to start allows and says so once per session', () => {
  const bin = join(root, 'bin-broken-node');
  mkdirSync(bin);
  writeFileSync(join(bin, 'node'), '#!/bin/sh\necho "SyntaxError: Unexpected token" >&2\nexit 1\n', { mode: 0o755 });
  const extra = { ...env, PATH: `${bin}${delimiter}${process.env.PATH}`, CLAUDE_PLUGIN_DATA: join(root, 'state-broken') };
  assert.match(JSON.parse(hook('gh pr new --body none', { session: 'b1', extra })).systemMessage, /node failed to run the hook/);
  assert.equal(hook('gh pr new --body none', { session: 'b1', extra }), '');
});
