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
import { check, loadConfig, parse, respond } from '../hooks/git-guardrails.mjs';

const root = mkdtempSync(join(tmpdir(), 'git-guardrails-'));
after(() => rmSync(root, { recursive: true, force: true }));

function repo(name, branch) {
  const dir = join(root, name);
  mkdirSync(dir);
  execFileSync('git', ['init', '-q', dir]);
  execFileSync('git', ['-C', dir, 'symbolic-ref', 'HEAD', `refs/heads/${branch}`]);
  return dir;
}
const onMain = repo('on-main', 'main');
const onFeat = repo('on-feat', 'feat/x');
const plain = join(root, 'plain');
mkdirSync(plain);
writeFileSync(join(root, 'merge.graphql'), 'mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }');

const run = (cmd, { cwd = onFeat, env = {} } = {}) => check(cmd, { cwd, config: loadConfig(env) });
const denies = (cmd, opts) => test(`denies ${JSON.stringify(cmd)}`, () => assert.ok(run(cmd, opts), 'expected a deny'));
const allows = (cmd, opts) => test(`allows ${JSON.stringify(cmd)}`, () => assert.equal(run(cmd, opts), null));

// Ported: the earlier push-delete guard suite.
for (const cmd of [
  'git push origin :refs/heads/x',
  'git push origin +:refs/heads/x',
  "git push origin ':refs/heads/example'",
  'git push origin ":refs/heads/example"',
  'git push origin ${N}:refs/heads/x',
  'git push origin $N:refs/heads/x',
  'git push origin "$N:refs/heads/x"',
  'git push origin ${SAFE:?}:refs/heads/safe $N:refs/heads/example',
  'git push origin --delete feat/x',
  'git push -d origin feat/x',
  'cd /tmp && git push origin :x',
  'gh pr close 5 --delete-branch',
  'gh pr close 5 -d',
  'git \\\npush origin --delete example',
  'git push origin \\\n":refs/heads/example"',
  'git push origin "\\\n:refs/heads/example"',
  'git push origin \\\n  $N:refs/heads/x',
]) denies(cmd);
for (const cmd of [
  'git push',
  'git push -u origin feat/x',
  'git push origin HEAD:refs/heads/feat/x',
  'git push origin ${N:?}:refs/heads/x',
  'git push origin "${N:?empty}:refs/heads/x" ${M:?}:refs/heads/y',
  "git push origin '$N:refs/heads/x'",
  'git push --force-with-lease origin feat/x',
  'gh pr close 5',
  'GIT_GUARDRAILS_ALLOW=1 git push origin --delete feat/x',
  'git log --format=%H:%s',
  'git push origin \\\n  HEAD:refs/heads/feat/x',
  'git \\\npush -u origin feat/x',
  'git push origin "${N:?}\\\n:refs/heads/x"',
]) allows(cmd);

// Ported: the strict gate suite, run with strict on.
const strict = { env: { GIT_GUARDRAILS_STRICT: 'true' } };
for (const cmd of [
  'git commit -m "x"',
  'git add -A && git commit -m "x"',
  'git -C /some/repo commit --amend',
  'git push',
  'git push origin feat/x',
  'git push --force-with-lease',
  'git reset --hard HEAD~1',
  'git clean -fd',
  'git branch -D old',
  'git stash drop',
  'gh pr merge 12 --squash',
  'gh api -X PUT repos/o/r/pulls/12/merge',
]) denies(cmd, strict);
denies('git merge dev', { ...strict, cwd: onMain });
for (const cmd of [
  'GIT_GUARDRAILS_ALLOW=1 git commit -m "x"',
  'GIT_GUARDRAILS_ALLOW=1 git push origin feat/x',
  'git status --short',
  'git log --oneline -5',
  'git diff --stat',
  'git fetch origin',
  'git branch --show-current',
  'git branch -d merged-branch',
  'git stash list',
  'git reset HEAD file.ts',
  'git clean -n',
  'gh pr view 12 --json state',
  'gh pr create --title x --body y',
  'npm run commit-lint',
  'echo "git commit"',
]) allows(cmd, strict);

// Ported: the merge guard cases, with main checked out. The first old version
// missed +main and refs/heads/main and denied feat/main-page.
const main = { cwd: onMain };
for (const cmd of [
  'gh pr merge 12',
  'git push origin HEAD:main',
  'git push',
  'git push --force origin main',
  'git merge feat/x',
  'git push origin +main',
  'git push origin refs/heads/main',
  'gh pr merge 12 --auto',
  'echo "GIT_GUARDRAILS_ALLOW=1" && gh pr merge 12',
]) denies(cmd, main);
for (const cmd of ['GIT_GUARDRAILS_ALLOW=1 gh pr merge 12', 'git push origin feat/main-page', 'gh pr view 12']) allows(cmd, main);

// Sources the old versions let through.
denies('git push origin $(git rev-parse HEAD~9):refs/heads/x');
denies('git push origin `cat sha.txt`:refs/heads/x');
denies('git push --mirror origin');
denies('git push --prune origin refs/heads/*:refs/heads/*');
denies('git push --del origin feat/x');
denies('git push -fd origin feat/x');
denies('gh api -X DELETE repos/o/r/git/refs/heads/feat/x');
denies('gh pr --repo o/r merge 12');
allows('git commit -m "$(cat <<\'EOF\'\nfix: stop the push -d flag\n\nIt\'s safe.\nEOF\n)"');
allows('git merge-base main HEAD', main);

// Protected branches.
for (const cmd of [
  'git push origin main',
  'git push -f origin master',
  'git push origin feat/x:main',
  'git push --force-with-lease origin HEAD:refs/heads/main',
  'git push origin "refs/heads/*:refs/heads/*"',
  'git push --all origin',
  'git push origin :',
  'git push origin main 2>&1 | tail -5',
  'git checkout main && git merge feat/x',
  'git checkout main && git push',
  `git -C ${onMain} merge feat/x`,
  `cd ${onMain} && git merge feat/x`,
  `cd ${onMain} && git push -u origin`,
]) denies(cmd);
denies('git push origin HEAD', main);
denies('git push -u origin', main);
for (const cmd of [
  'git push origin HEAD',
  'git push origin main:feat/x',
  'git push origin feat/x 2>&1 | tail -5',
  'git push origin feat/x > main',
  'git push --dry-run origin main',
  'git push -n origin main',
  'git push --tags',
  'git merge main',
  'git checkout -b feat/y origin/main',
]) allows(cmd);
allows('git merge --abort', main);
allows('git push', { cwd: plain });
allows('git push origin release/1.2');
denies('git push origin release/1.2', { env: { GIT_GUARDRAILS_PROTECTED_BRANCHES: 'main,release/*' } });
allows('git push origin main', { env: { GIT_GUARDRAILS_PROTECTED_BRANCHES: '' } });
denies('git push origin dev', { env: { GIT_GUARDRAILS_PROTECTED_BRANCHES: '["dev"]' } });

// History-destroying git.
for (const cmd of [
  'git reset --hard origin/main',
  'git clean -fdx',
  'git clean --force',
  'git branch -d -f old',
  'git branch --delete --force old',
  'git stash clear',
  'git branch --merged | xargs git branch -D',
  'sudo -u me git reset --hard',
]) denies(cmd);
for (const cmd of ['git clean -nd', 'git stash pop', 'git reset --soft HEAD~1', 'git branch -d old']) allows(cmd);

// Merges through the API.
for (const cmd of [
  'gh api --method=PUT repos/o/r/pulls/12/merge',
  'gh api -XPUT repos/o/r/pulls/$N/merge',
  'gh api repos/o/r/merges -f base=main -f head=feat/x',
  "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'",
  'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }"',
  'gh api graphql -F query=@merge.graphql',
  "gh api graphql --input - <<'EOF'\n{\"query\": \"mutation { mergePullRequest(input: {}) { clientMutationId } }\"}\nEOF",
  'curl -X PUT -H "Authorization: token t" https://api.github.com/repos/o/r/pulls/1/merge',
  'curl https://api.github.com/graphql -d \'{"query":"mutation{enablePullRequestAutoMerge(input:{}){clientMutationId}}"}\'',
]) denies(cmd, { cwd: root });
for (const cmd of [
  'gh api repos/o/r/pulls/12/merge',
  "gh api graphql -f query='query { viewer { login } }'",
  'gh api repos/o/r/pulls/12 --jq .mergeable',
  'curl -s https://api.github.com/repos/o/r/pulls/1',
]) allows(cmd, { cwd: root });

// Wrappers and shell syntax.
for (const cmd of [
  "sh -c 'git push origin main'",
  'bash -lc "gh pr merge 3"',
  'zsh -c "git push origin \\"\\$N:refs/heads/x\\""',
  'eval "git push origin --delete x"',
  "bash <<'EOF'\ngit push origin main\nEOF",
  'bash <<< "git reset --hard"',
  'echo $(gh pr merge 3)',
  'x=$(git push origin :x)',
  '(cd /tmp && git push origin :x)',
  'if git push origin main; then echo ok; fi',
  'command git push origin main',
  'nohup git push origin main &',
  'time git push origin main',
  'env FOO=1 git push origin main',
  'timeout 30 git push origin main',
  '/usr/bin/git push origin main',
  'git -c core.pager=cat --no-pager push origin main',
  'GIT_GUARDRAILS_ALLOW=1 git commit -m x && git push origin main',
  'export GIT_GUARDRAILS_ALLOW=1; git push origin main',
  'GIT_GUARDRAILS_ALLOW=0 git push origin main',
  'GIT_GUARDRAILS_ALLOW=1; git push origin main',
  'git status # quiet\ngit push origin main',
]) denies(cmd);
for (const cmd of [
  "GIT_GUARDRAILS_ALLOW=1 bash -c 'git push origin main'",
  "bash -c 'GIT_GUARDRAILS_ALLOW=1 git push origin main'",
  'env GIT_GUARDRAILS_ALLOW=1 git push origin main',
  'git add -A && GIT_GUARDRAILS_ALLOW=1 git push origin main',
  "cat > notes.md <<'EOF'\ngit push origin --delete x\ngh pr merge 1\nEOF",
  'cat > notes.md <<-EOF\n\tgit push origin main\n\tEOF\necho done',
  'git status # git push origin main',
  'git status # ; git push origin main',
  'git commit -m "fix: push -d flag docs"',
  'gh pr create --title x --body "never git push -d here"',
  'grep -rn "gh pr merge" docs/',
  'echo "git push origin main" | wc -c',
  'gh pr create --body "$(cat <<\'EOF\'\nIt\'s ready. Do not run gh pr merge yet.\nEOF\n)"',
]) allows(cmd);
// A heredoc inside $(...) with an apostrophe must not hide what follows it.
denies('gh pr create --body "$(cat <<\'EOF\'\nIt\'s ready.\nEOF\n)" && gh pr merge 1');

// Each rule can be switched off.
allows('gh pr merge 1', { env: { GIT_GUARDRAILS_BLOCK_MERGES: 'false' } });
allows('git push origin --delete x', { env: { GIT_GUARDRAILS_BLOCK_BRANCH_DELETE: 'false' } });
allows('git reset --hard', { env: { GIT_GUARDRAILS_BLOCK_DESTRUCTIVE: 'false' } });
denies('git push origin --delete main', { env: { GIT_GUARDRAILS_BLOCK_BRANCH_DELETE: 'false' } });
allows('git commit -m x');
denies('git commit -m x', { env: { CLAUDE_PLUGIN_OPTION_STRICT: 'true' } });

// Review round 1.
// 1. A refspec that is only an expansion usually names the checked-out branch.
denies('git push -u origin "$(git branch --show-current)"', main);
denies('git push origin $(git rev-parse --abbrev-ref HEAD)', main);
allows('git push -u origin "$(git branch --show-current)"');
// 2. The override goes directly before the blocked command, so a retry that follows the message passes.
allows('git add -A && GIT_GUARDRAILS_ALLOW=1 git commit -m x', strict);
allows('cd /tmp && GIT_GUARDRAILS_ALLOW=1 git push origin main');
denies('GIT_GUARDRAILS_ALLOW=1 cd /tmp && git push origin main');
// 4. Shell options and `--` before the script.
denies('bash -c -- "git push origin main"');
denies("bash -euo pipefail -c 'git push origin main'");
denies("sh -e -c 'gh pr merge 1'");
allows('bash -o pipefail -c "git status"');
allows('bash ./deploy.sh');
// 5. git accepts abbreviated long options.
denies('git reset --har HEAD~1');
denies('git clean --forc');
denies('git branch --delete --forc old');
// 6. An unquoted heredoc still runs its $(...) and backticks.
denies('cat > body.md <<EOF\nSee `gh pr merge 3`\nEOF');
denies('cat > body.md <<EOF\nRun $(git reset --hard)\nEOF');
allows("cat > body.md <<'EOF'\nSee `gh pr merge 3` and $(git reset --hard)\nEOF");
allows('cat > body.md <<EOF\nBuilt on $(date) with `node --version`\nEOF');
// 7. GraphQL mergeBranch, and REST updates to a protected branch ref.
denies("gh api graphql -f query='mutation { mergeBranch(input:{repositoryId:\"x\", base:\"main\", head:\"feat\"}) { clientMutationId } }'");
denies('gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc -F force=true');
allows('gh api -X PATCH repos/o/r/git/refs/heads/feat/x -f sha=abc');
allows('gh api repos/o/r/git/refs/heads/main');
// 8. curl only for api.github.com, GraphQL mutations only on the graphql endpoint.
allows("curl -X POST http://localhost:3000/api/merges -d '{}'");
allows("gh api repos/o/r/issues/3/comments -f body='we run mergePullRequest after review'");
// 9. More wrappers.
denies('caffeinate -i git push origin main');
denies('stdbuf -oL git push origin main');
denies('find . -maxdepth 0 -exec git push origin main \\;');
allows("find . -name '*.md' -exec grep -l main {} +");
// 11. Nesting past the cap is denied instead of skipped.
const nest = (cmd, n) => Array.from({ length: n }).reduce((s) => `echo $(${s})`, cmd);
denies(nest('gh pr merge 1', 11));
allows(nest('git status', 30));
denies(nest('git status', 40));
test('denies 20000 levels of $(...) without overflowing the stack', () => {
  assert.match(run(nest('git status', 20000)), /nested too deeply/);
});
// Owner call: --ff-only can't create a merge commit.
allows('git checkout main && git merge --ff-only origin/main');
allows('git merge --ff-only origin/main', main);

// Review round 2.
// Only a refspec that is one whole expansion stands for the checked-out branch.
denies('git push origin $B', main);
denies('git push origin "${B:?}"', main);
denies('git push -u origin "$(git branch --show-current)"', main);
for (const cmd of [
  'git push origin "v$VERSION"',
  'git push origin "refs/tags/$TAG"',
  'git push origin "refs/tags/v$(node -p 1)"',
  'git push origin "feat/$NAME"',
]) allows(cmd, main);
// Commits through the contents API.
denies('gh api -X PUT repos/o/r/contents/README.md -f message=x -f content=eA== -f branch=main');
denies('gh api -X PUT repos/o/r/contents/README.md -f message=x -f content=eA==');
denies('gh api -X DELETE repos/o/r/contents/old.md -f message=x -f sha=abc --field branch=master');
denies('curl -X PUT https://api.github.com/repos/o/r/contents/a.md -d \'{"message":"x","content":"eA==","branch":"main"}\'');
allows('gh api -X PUT repos/o/r/contents/README.md -f message=x -f content=eA== -f branch=feat/x');
allows('gh api repos/o/r/contents/README.md');
allows('gh api -X PUT repos/o/r/contents/README.md -f message=x -f content=eA==', { env: { GIT_GUARDRAILS_PROTECTED_BRANCHES: '' } });
// Every -exec of a find is read.
denies("find . -name '*.md' -exec grep -l x {} \\; -exec git push origin main \\;");
denies('find . -execdir true \\; -ok git branch -D {} +');
allows("find . -name '*.log' -exec rm {} \\; -exec echo git push origin main \\;");

// Launch review.
// Every checkout or switch moves the branch the hook reads, not only one onto a protected branch.
writeFileSync(join(onFeat, 'notes.md'), '');
for (const cmd of [
  'git checkout main && git pull && git checkout feat/x && git merge main',
  'git switch main && git pull --ff-only && git switch feat/x && git merge main',
  'git checkout main && git pull && git checkout -b feat2 && git merge origin/feat',
  'git switch main && git switch -c fix && git merge main',
  'git switch main && git switch --create=fix && git merge main',
  'git checkout main && git checkout --detach && git merge x',
  'git checkout main && git checkout - && git merge main',
]) allows(cmd);
for (const cmd of [
  'git checkout feat/x && git checkout main && git merge x',
  'git checkout main && git checkout notes.md && git merge x',
  'git checkout main && git checkout -- notes.md && git merge x',
  'git checkout main && git checkout feat/x notes.md && git merge x',
  'git checkout -t origin/main && git merge x',
]) denies(cmd);
denies('git checkout "$B" && git merge x', main);
denies('git switch feat/x && git switch - && git merge x', main);
// A refspec or branch that is one whole variable set earlier in the same command.
for (const cmd of [
  'B=main; git push origin "$B"',
  'BR=main && git push origin $BR',
  'export B=main; git push origin "${B}"',
  'B=main; git checkout "$B" && git merge x',
]) denies(cmd);
allows('B=feat/y; git push origin "$B"', main);
denies('B=main; B=$(git branch --show-current); git push origin "$B"', main);
allows('B=main git push origin "$B"');

test('an internal error lets the command through with a note once per session', () => {
  const env = { CLAUDE_PLUGIN_DATA: join(root, 'state-error') };
  const broken = (session) => ({ session_id: session, get tool_input() { throw new Error('boom'); } });
  assert.match(respond(broken('e1'), env).systemMessage, /internal error: boom/);
  assert.equal(respond(broken('e1'), env), null);
  assert.ok(respond(broken('e2'), env).systemMessage);
  assert.equal(respond({ tool_input: { command: 'git status' }, cwd: onFeat }, env), null);
});

test('config: plugin option wins over the plain env var, then the default', () => {
  assert.deepEqual(loadConfig({}), {
    blockMerges: true,
    protectedBranches: ['main', 'master'],
    blockBranchDelete: true,
    blockDestructive: true,
    strict: false,
  });
  assert.equal(loadConfig({ CLAUDE_PLUGIN_OPTION_STRICT: 'false', GIT_GUARDRAILS_STRICT: 'true' }).strict, false);
  assert.equal(loadConfig({ GIT_GUARDRAILS_STRICT: '1' }).strict, true);
  assert.equal(loadConfig({ GIT_GUARDRAILS_STRICT: 'maybe' }).strict, false);
  assert.deepEqual(loadConfig({ CLAUDE_PLUGIN_OPTION_PROTECTED_BRANCHES: 'main,develop' }).protectedBranches, ['main', 'develop']);
  assert.deepEqual(loadConfig({ GIT_GUARDRAILS_PROTECTED_BRANCHES: 'trunk prod' }).protectedBranches, ['trunk', 'prod']);
});

test('the deny reason names the action and the way forward', () => {
  const reason = run('git push origin main');
  assert.match(reason, /git-guardrails blocked git push to main/);
  assert.match(reason, /GIT_GUARDRAILS_ALLOW=1 written directly before the blocked command itself, not before cd/);
  assert.match(run('git push origin $N:refs/heads/x'), /\$\{VAR:\?\}/);
});

test('parse keeps quoted words whole and drops redirects', () => {
  const [seg] = parse('git commit -m "a b" 2>/dev/null');
  assert.deepEqual(seg.words.map((w) => w.text), ['git', 'commit', '-m', 'a b']);
});

// The launcher, end to end.
const launcher = join(dirname(fileURLToPath(import.meta.url)), '..', 'hooks', 'git-guardrails.sh');
const cleanEnv = Object.fromEntries(
  Object.entries(process.env).filter(([k]) => !/^(CLAUDE_PLUGIN_OPTION_|GIT_GUARDRAILS_)/.test(k)),
);
function hook(command, { session = 's1', env = {}, input } = {}) {
  const payload = input ?? JSON.stringify({ session_id: session, cwd: onFeat, tool_name: 'Bash', tool_input: { command } });
  return execFileSync('/bin/sh', [launcher], { input: payload, env: { ...cleanEnv, ...env } }).toString();
}

test('launcher: denies with PreToolUse JSON and stays silent on allow', () => {
  const out = JSON.parse(hook("git push origin ':refs/heads/x'"));
  assert.equal(out.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.equal(out.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal(hook('git status'), '');
  assert.equal(hook('', { input: 'not json' }), '');
  assert.equal(hook('git commit -m x', { env: { GIT_GUARDRAILS_STRICT: 'true' } }).includes('"deny"'), true);
});

test('launcher: without node it allows and says so once per session', () => {
  const bin = join(root, 'bin-no-node');
  mkdirSync(bin);
  for (const tool of ['cat', 'sed', 'mkdir']) {
    const found = process.env.PATH.split(delimiter).map((d) => join(d, tool)).find((p) => existsSync(p));
    symlinkSync(found, join(bin, tool));
  }
  const env = { PATH: bin, CLAUDE_PLUGIN_DATA: join(root, 'state') };
  const first = JSON.parse(hook('git push origin main', { session: 'abc', env }));
  assert.match(first.systemMessage, /node is not on PATH/);
  assert.equal(hook('git push origin main', { session: 'abc', env }), '');
  assert.match(hook('git push origin main', { session: 'def', env }), /systemMessage/);
});

test('launcher: a node that fails to start allows and says so once per session', () => {
  const bin = join(root, 'bin-broken-node');
  mkdirSync(bin);
  writeFileSync(join(bin, 'node'), '#!/bin/sh\necho "SyntaxError: Unexpected token" >&2\nexit 1\n', { mode: 0o755 });
  const env = { PATH: `${bin}${delimiter}${process.env.PATH}`, CLAUDE_PLUGIN_DATA: join(root, 'state-broken') };
  assert.match(JSON.parse(hook('gh pr merge 1', { session: 'b1', env })).systemMessage, /node failed to run the hook/);
  assert.equal(hook('gh pr merge 1', { session: 'b1', env }), '');
});
