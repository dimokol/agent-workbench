// git-guardrails: a Claude Code PreToolUse hook for the Bash tool.
// It splits the command the way a shell would (quotes, escapes, line
// continuations, $(...), heredocs, sh -c, eval, find -exec) and denies PR merges,
// pushes to protected branches, remote branch deletion and history-destroying
// git. A blocked command passes when GIT_GUARDRAILS_ALLOW=1 sits directly before it.
// It is a speed bump against mistakes: scripts and git aliases go unseen.
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ALLOW = 'GIT_GUARDRAILS_ALLOW';
// Stands in for one expansion the hook can't evaluate: $VAR, ${...}, $(...), `...`.
const MARK = '\u0000';
// Past this many levels of $(...), sh -c or eval the hook stops reading and denies.
const MAX_DEPTH = 32;
const TOO_DEEP = new Error('nested too deeply');

// Plugin option first, then the plain env var for hand-wired setups, then the default.
export function loadConfig(env = process.env) {
  const raw = (key) => env[`CLAUDE_PLUGIN_OPTION_${key.toUpperCase()}`] ?? env[`GIT_GUARDRAILS_${key.toUpperCase()}`];
  const bool = (key, fallback) => {
    const v = String(raw(key) ?? '').trim().toLowerCase();
    return ['1', 'true', 'yes', 'on'].includes(v) ? true : ['0', 'false', 'no', 'off'].includes(v) ? false : fallback;
  };
  let branches = raw('protected_branches') ?? ['main', 'master'];
  if (typeof branches === 'string') {
    try { branches = JSON.parse(branches); } catch {}
    branches = Array.isArray(branches) ? branches.map(String) : String(branches).split(/[\s,]+/);
  }
  return {
    blockMerges: bool('block_merges', true), blockBranchDelete: bool('block_branch_delete', true),
    blockDestructive: bool('block_destructive', true), strict: bool('strict', false),
    protectedBranches: branches.map((b) => b.trim()).filter(Boolean),
  };
}

// Splits a command line into simple commands ("segments") of words, the way the
// shell would after removing quotes. A word keeps `text` (expansions replaced by
// MARK), `raw` (expansions kept, for re-parsing an sh -c string) and `vars`.
// A segment also carries the commands inside its $(...) and backticks (`subs`)
// and the text its heredocs and here-strings feed it (`stdin`).
export function parse(cmd, level = 0) {
  return scan(cmd, 0, null, level).segs;
}

function scan(cmd, i, closer, level) {
  if (level > MAX_DEPTH) throw TOO_DEEP;
  const segs = [];
  const heredocs = [];
  let seg, word = null, quote = null, redirect = null, depth = 0;
  const next = () => (seg = { words: [], stdin: '', subs: [] });
  const add = (text, raw = text) => {
    word ??= { text: '', raw: '', vars: [] };
    word.text += text;
    word.raw += raw;
  };
  const flush = () => {
    if (word && redirect === '<<<') seg.stdin += `${word.raw}\n`;
    else if (word && !redirect) seg.words.push(word);
    if (word) redirect = null;
    word = null;
  };
  const end = () => {
    flush();
    redirect = null;
    if (seg.words.length || seg.stdin || seg.subs.length) segs.push(seg);
    next();
  };
  next();
  for (; i < cmd.length; i++) {
    const c = cmd[i];
    if (quote === "'") { if (c === "'") quote = null; else add(c); continue; }
    if (c === '\\' && i + 1 < cmd.length) {
      const n = cmd[++i];
      if (n !== '\n') add(quote === '"' && !'$`"\\'.includes(n) ? `\\${n}` : n); // backslash-newline: both dropped
      continue;
    }
    if (c === '`' && closer === '`') break;
    if (c === '`' || (c === '$' && cmd[i + 1] === '(')) {
      const from = i;
      const sub = scan(cmd, i + (c === '`' ? 1 : 2), c === '`' ? '`' : ')', level + 1);
      seg.subs.push(...sub.segs);
      i = sub.i;
      add(MARK, cmd.slice(from, i + 1));
      word.vars.push(cmd.slice(from, i + 1));
      continue;
    }
    const m = c === '$' && /^\$(\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/.exec(cmd.slice(i, i + 256));
    if (m) {
      add(MARK, m[0]);
      word.vars.push(m[0]);
      i += m[0].length - 1;
    } else if (quote === '"') {
      if (c === '"') quote = null; else add(c);
    } else if (c === "'" || c === '"') {
      quote = c;
      add('');
    } else if (c === '#' && !word) {
      const nl = cmd.indexOf('\n', i);
      i = (nl < 0 ? cmd.length : nl) - 1;
    } else if (c === ' ' || c === '\t') {
      flush();
    } else if (c === '<' || c === '>' || (c === '&' && cmd[i + 1] === '>')) {
      if (word && /^\d+$/.test(word.raw)) word = null; // the fd in 2>&1
      else flush();
      const op = /^(<<<|<<-?|&>>?|[<>][<>&|]?)/.exec(cmd.slice(i, i + 3))[0];
      i += op.length - 1;
      const d = op.startsWith('<<') && op !== '<<<' && /^[ \t]*((?:'[^']*'|"[^"]*"|\\.|[^\s;&|<>()])+)/.exec(cmd.slice(i + 1, i + 300));
      if (d) {
        heredocs.push({ seg, delim: d[1].replace(/['"\\]/g, ''), tabs: op === '<<-', quoted: /['"\\]/.test(d[1]) });
        i += d[0].length;
      } else if (!op.startsWith('<<') || op === '<<<') redirect = op;
    } else if (c === '\n') {
      end();
      i = readHeredocs(cmd, i, heredocs, level);
    } else if (c === '(') {
      depth++;
      end();
    } else if (c === ')') {
      if (closer === ')' && depth === 0) break;
      depth--;
      end();
    } else if (c === ';' || c === '&' || c === '|') end();
    else add(c);
  }
  end();
  return { segs, i };
}

// Heredoc bodies start after the newline that ends their command line. With an
// unquoted delimiter the shell still runs the $(...) and backticks in the body.
function readHeredocs(cmd, i, heredocs, level) {
  for (const h of heredocs.splice(0)) {
    let body = '';
    while (i < cmd.length - 1) {
      const nl = cmd.indexOf('\n', i + 1);
      const line = cmd.slice(i + 1, (i = nl < 0 ? cmd.length : nl));
      if ((h.tabs ? line.replace(/^\t+/, '') : line) === h.delim) break;
      body += `${line}\n`;
    }
    h.seg.stdin += body;
    for (let k = 0; !h.quoted && k < body.length; k++) {
      if (body[k] === '\\') k++;
      else if (body[k] === '`' || (body[k] === '$' && body[k + 1] === '(')) {
        const sub = scan(body, k + (body[k] === '`' ? 1 : 2), body[k] === '`' ? '`' : ')', level + 1);
        h.seg.subs.push(...sub.segs);
        k = sub.i;
      }
    }
  }
  return i;
}

const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'ash']);
// Words that run the rest of the line as a command, with their options that take a value.
const PREFIXES = {
  command: [], builtin: [], exec: [], nohup: [], time: [], '!': [], '{': [], '}': [],
  if: [], then: [], else: [], elif: [], do: [], while: [], until: [],
  env: ['-u', '-C'], sudo: ['-u', '-g', '-h', '-p'], nice: ['-n'], timeout: ['-s', '-k'],
  xargs: ['-I', '-n', '-L', '-P', '-d', '-E', '-s', '-a'], caffeinate: ['-t', '-w'], stdbuf: ['-i', '-o', '-e'],
};

// Skips leading VAR=value assignments and wrappers such as `sudo -u me` or `timeout 30`.
function skipPrefixes(words) {
  const assigns = [];
  let i = 0;
  while (i < words.length) {
    const t = words[i].text;
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(t)) assigns.push(words[i++].text);
    else if (!Object.hasOwn(PREFIXES, t)) break;
    else {
      for (i++; i < words.length && /^-./.test(words[i].text); i++) if (PREFIXES[t].includes(words[i].text)) i++;
      if (t === 'timeout') i++; // its duration
    }
  }
  return { i, assigns };
}

// The script a shell runs: the operand after -c (options may come before it),
// its stdin when there is no operand, or null for a script file.
function shellScript(args, stdin) {
  let hasC = false;
  for (let k = 1; k < args.length; k++) {
    const a = args[k].text;
    if (a === '--') return hasC ? args[k + 1]?.raw ?? '' : null;
    if (/^[-+][a-zA-Z]+$/.test(a)) {
      hasC ||= a[0] === '-' && a.includes('c');
      if (/[oO]$/.test(a)) k++; // -o pipefail
    } else if (a === '--rcfile' || a === '--init-file') k++;
    else if (!a.startsWith('--')) return hasC ? args[k].raw : null;
  }
  return hasC ? '' : stdin;
}

function walk(segs, ctx, depth) {
  if (depth > MAX_DEPTH) throw TOO_DEEP;
  for (const seg of segs) {
    const reason = checkSegment(seg, ctx, depth);
    if (reason) return reason;
  }
  return null;
}

function checkSegment(seg, ctx, depth) {
  const inSubs = walk(seg.subs, { ...ctx, allow: false }, depth + 1);
  if (inSubs) return inSubs;
  const { i, assigns } = skipPrefixes(seg.words);
  const allow = ctx.allow || assigns.includes(`${ALLOW}=1`);
  const args = seg.words.slice(i);
  const name = basename(args[0]?.text ?? '');
  const inner = { ...ctx, allow };
  // `B=main; git push origin "$B"`: a bare assignment sets what later commands expand.
  if (!args.length || name === 'export') remember(args.length ? args.slice(1).map((w) => w.text) : assigns, ctx.vars);
  if (name === 'cd' || name === 'pushd') {
    if (args[1]?.text !== '-') ctx.cwd = resolvePath(ctx.cwd, args[1]?.text ?? '~');
    return null;
  }
  if (SHELLS.has(name)) return walk(parse(shellScript(args, seg.stdin) ?? '', depth + 1), inner, depth + 1);
  if (name === 'eval') return walk(parse(args.slice(1).map((a) => a.raw).join(' '), depth + 1), inner, depth + 1);
  if (name === 'find') {
    for (let k = 0; k < args.length; k++) {
      if (!/^-(exec|execdir|ok|okdir)$/.test(args[k].text)) continue;
      const stop = args.findIndex((a, j) => j > k && (a.text === ';' || a.text === '+'));
      const words = args.slice(k + 1, stop < 0 ? args.length : stop);
      const reason = checkSegment({ words, stdin: '', subs: [] }, inner, depth + 1);
      if (reason) return reason;
      k = stop < 0 ? args.length : stop;
    }
    return null;
  }
  if (allow) return null;
  if (name === 'git') return checkGit(args.slice(1), ctx);
  if (name === 'gh') return checkGh(args.slice(1), seg, ctx);
  if (name === 'curl' && args.some((a) => a.text.includes('api.github.com'))) return checkApi(args.slice(1), seg, ctx, CURL_FLAGS);
  return null;
}

function remember(assigns, vars) {
  for (const a of assigns) {
    const [, name, value] = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s.exec(a) ?? [];
    if (!name) continue;
    if (value.includes(MARK)) vars.delete(name);
    else vars.set(name, value);
  }
}

// Fills in each $NAME or ${NAME} that an earlier NAME=literal in the same command set.
function expand(w, vars) {
  if (!w.vars.length || !vars.size) return w;
  const parts = w.text.split(MARK);
  const left = [];
  let text = parts[0];
  w.vars.forEach((v, k) => {
    const m = /^\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})$/.exec(v);
    const name = m && (m[1] ?? m[2]);
    if (name && vars.has(name)) text += vars.get(name);
    else {
      text += MARK;
      left.push(v);
    }
    text += parts[k + 1];
  });
  return { ...w, text, vars: left };
}

const resolvePath = (base, p) => (p === '~' || p.startsWith('~/') ? join(homedir(), p.slice(1)) : resolve(base, p));

function checkedOut(dir, ctx) {
  if (!ctx.onBranch.has(dir)) {
    let branch = null;
    const opts = { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 3000 };
    try { branch = execFileSync('git', ['-C', dir, 'symbolic-ref', '--short', '-q', 'HEAD'], opts).trim() || null; } catch {}
    ctx.onBranch.set(dir, branch);
  }
  return ctx.onBranch.get(dir);
}

const glob = (p) => new RegExp(`^${p.split('*').map((s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*')}$`);

function isProtected(ref, cfg) {
  const name = String(ref ?? '').replace(/^refs\/heads\//, '');
  if (!name || name.startsWith('refs/') || name.includes(MARK)) return false;
  return cfg.protectedBranches.some((p) => glob(p).test(name) || (name.includes('*') && glob(name).test(p)));
}

// git accepts any unambiguous prefix of a long option, so --har means --hard.
const isLong = (a, full, min) => {
  const name = a.startsWith('--') ? a.slice(2).split('=')[0] : '';
  return name.length >= min && full.startsWith(name);
};

const ASK =
  `Only if the user's latest message asked for exactly this, retry with ${ALLOW}=1 written directly before the blocked ` +
  'command itself, not before cd or an earlier command in the chain (each blocked command needs its own). Otherwise stop and ask the user.';
const MERGES = "merging needs the user's explicit go.";
const DELETES = 'it deletes a branch on the remote.';
const LOSES = 'it throws away work that git cannot easily bring back.';
const STRICT = "strict mode is on, so commits and pushes wait for the user's explicit go.";
const deny = (what, why) => `git-guardrails blocked ${what}: ${why} ${ASK}`;
const protectedWhy = (b) => `${b} is a protected branch, and changing it needs the user's explicit go.`;

const GIT_VALUE_OPTS = ['-c', '--git-dir', '--work-tree', '--namespace', '--config-env'];

function checkGit(words, ctx) {
  const cfg = ctx.config;
  const argv = words.map((w) => expand(w, ctx.vars));
  let dir = ctx.cwd;
  let i = 0;
  for (; i < argv.length && argv[i].text.startsWith('-'); i++) {
    if (argv[i].text === '-C') dir = resolvePath(dir, argv[++i]?.text ?? '.');
    else if (GIT_VALUE_OPTS.includes(argv[i].text)) i++;
  }
  const verb = argv[i]?.text;
  const rest = argv.slice(i + 1);
  const t = rest.map((a) => a.text);
  const short = t.filter((a) => /^-[a-zA-Z]+$/.test(a)).join('');
  const long = (full, min) => t.some((a) => isLong(a, full, min));
  const branch = () => checkedOut(dir, ctx);
  if (verb === 'push') return checkPush(rest, branch, cfg);
  if (verb === 'commit') return cfg.strict ? deny('git commit', STRICT) : null;
  // --ff-only can't create a merge commit, and pushing the result is still guarded.
  if (verb === 'merge' && cfg.blockMerges && !['--abort', '--quit', '--ff-only'].some((f) => t.includes(f))) {
    const b = branch();
    return isProtected(b, cfg) ? deny(`git merge while ${b} is checked out`, protectedWhy(b)) : null;
  }
  if (verb === 'checkout' || verb === 'switch') {
    // Later commands in the line run on the branch this one leaves checked out:
    // `git checkout main && git merge x` merges into main, though main isn't checked out yet.
    const target = checkoutTarget(verb, rest, dir, cfg);
    if (target === undefined) ctx.onBranch.delete(dir); // can't tell, so ask git
    else if (target !== KEEP) ctx.onBranch.set(dir, target);
    return null;
  }
  if (!cfg.blockDestructive) return null;
  const force = short.includes('f') || long('force', 3);
  if (verb === 'reset' && long('hard', 2)) return deny('git reset --hard', LOSES);
  if (verb === 'clean' && force && !short.includes('n') && !t.includes('--dry-run')) return deny('git clean -f', LOSES);
  const del = short.includes('d') || long('delete', 3);
  if (verb === 'branch' && (short.includes('D') || (del && force))) return deny('git branch -D', LOSES);
  const stash = t.find((a) => !a.startsWith('-'));
  if (verb === 'stash' && (stash === 'drop' || stash === 'clear')) return deny(`git stash ${stash}`, LOSES);
  return null;
}

const KEEP = Symbol('only files change');

// Where a checkout or switch leaves HEAD: a branch name, null when detached,
// undefined when the hook can't tell, or KEEP when it only restores files.
function checkoutTarget(verb, words, dir, cfg) {
  const pos = [];
  let track = false;
  for (let k = 0; k < words.length; k++) {
    const a = words[k].text;
    const made = /^(?:-[bBcC]|--orphan|--create|--force-create)(?:=(.*))?$/s.exec(a);
    if (made) {
      const name = made[1] ?? words[k + 1]?.text;
      return name && !name.includes(MARK) ? name : undefined;
    }
    if (a === '--detach' || (verb === 'switch' && a === '-d')) return null;
    if (a === '--' || a === '-p' || a === '--patch' || a.startsWith('--pathspec-from-file')) return KEEP;
    if (a === '-t' || a.startsWith('--track')) track = true;
    else if (a === '-' || !a.startsWith('-')) pos.push(a);
  }
  if (pos.length !== 1) return KEEP; // `git checkout main file.txt` restores a file
  if (pos[0] === '-' || pos[0].includes(MARK)) return undefined;
  const name = track ? pos[0].replace(/^[^/]+\//, '') : pos[0]; // -t origin/x creates x
  // git reads `git checkout notes.md` as a file restore unless a ref has that name.
  if (verb === 'checkout' && !isProtected(name, cfg) && existsSync(resolve(dir, pos[0]))) return KEEP;
  return name;
}

function checkPush(argv, branch, cfg) {
  const pos = [];
  let all = false, tags = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i].text;
    if (a === '--') { pos.push(...argv.slice(i + 1)); break; }
    if (a.startsWith('--')) {
      if (isLong(a, 'dry-run', 2)) return null;
      const deletes = ['delete', 'mirror'].some((f) => isLong(a, f, 2)) || isLong(a, 'prune', 3);
      if (cfg.blockBranchDelete && deletes) return deny(`git push ${a}`, DELETES);
      if (['all', 'branches', 'mirror'].some((f) => isLong(a, f, 2))) all = true;
      if (a === '--tags') tags = true;
      if (['--repo', '--receive-pack', '--exec', '--push-option'].includes(a)) i++;
    } else if (/^-./.test(a)) {
      const o = a.indexOf('o', 1); // -o takes a value: the rest of the word, or the next word
      const flags = o < 0 ? a.slice(1) : a.slice(1, o);
      if (o === a.length - 1) i++;
      if (flags.includes('n')) return null; // dry run
      if (cfg.blockBranchDelete && flags.includes('d')) return deny(`git push ${a}`, DELETES);
    } else pos.push(argv[i]);
  }
  const refspecs = pos.slice(1); // the first one is the remote
  for (const w of refspecs) {
    const spec = w.text.replace(/^\+/, '');
    const colon = spec.indexOf(':');
    const src = colon < 0 ? spec : spec.slice(0, colon);
    let dst = colon < 0 ? spec : spec.slice(colon + 1);
    const shown = w.raw.replace(/\n/g, ' ');
    if (colon >= 0 && cfg.blockBranchDelete && src === '' && dst !== '') {
      return deny(`git push ${shown}`, `an empty source deletes ${dst} on the remote. If a variable was meant to fill it, it came out empty, so check it first.`);
    }
    // The hook sees the command before the shell expands it, so a variable in
    // the source passes only when written ${VAR:?}, which aborts if it's empty.
    const vars = w.vars.slice(0, src.split(MARK).length - 1);
    if (colon >= 0 && cfg.blockBranchDelete && vars.some((v) => !/^\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}$/.test(v))) {
      return deny(`git push ${shown}`, 'the source comes from a variable or command, and if that comes out empty the push deletes the remote branch. Write it as ${VAR:?} so an empty value aborts.');
    }
    if (spec === ':') all = true; // "matching": every branch that exists on both sides
    // HEAD names the checked-out branch, and so, usually, does a refspec that is one whole
    // expansion such as "$(git branch --show-current)". "v$VERSION" or "feat/$NAME" can't be main.
    else if (colon < 0 && (spec === 'HEAD' || spec === '@' || spec === MARK)) dst = branch();
    if (isProtected(dst, cfg)) {
      return deny(`git push to ${dst}`, dst.includes('*') ? 'that pattern covers a protected branch.' : protectedWhy(dst));
    }
  }
  if (all && cfg.protectedBranches.length) {
    return deny('a git push of every branch', `it includes the protected branches (${cfg.protectedBranches.join(', ')}).`);
  }
  const b = !refspecs.length && !all && !tags ? branch() : null;
  if (isProtected(b, cfg)) return deny(`git push while ${b} is checked out`, protectedWhy(b));
  return cfg.strict ? deny('git push', STRICT) : null;
}

function checkGh(argv, seg, ctx) {
  const cfg = ctx.config;
  const t = argv.map((a) => a.text);
  const [group, verb] = t.filter((a, k) => !a.startsWith('-') && t[k - 1] !== '-R' && t[k - 1] !== '--repo');
  if (group === 'pr' && verb === 'merge' && cfg.blockMerges) return deny('gh pr merge', MERGES);
  if (group === 'pr' && verb === 'close' && cfg.blockBranchDelete && (t.includes('-d') || t.includes('--delete-branch'))) {
    return deny('gh pr close --delete-branch', 'it deletes the PR branch, and a PR stacked on that branch closes with it.');
  }
  return group === 'api' ? checkApi(argv.slice(t.indexOf('api') + 1), seg, ctx, GH_API_FLAGS) : null;
}

const GH_API_FLAGS = { method: ['-X', '--method'], body: ['-f', '-F', '--field', '--raw-field', '--input'] };
const CURL_FLAGS = { method: ['-X', '--request'], body: ['-d', '--data', '--data-raw', '--data-binary', '--json'] };

// Merges, branch deletes and protected-branch updates sent straight to the GitHub API.
function checkApi(argv, seg, ctx, flags) {
  const cfg = ctx.config;
  const known = [...flags.method, ...flags.body];
  const text = [seg.stdin];
  const urls = [];
  const fields = [];
  let method = '', body = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i].text;
    const m = /^(--[\w-]+)=(.*)$/s.exec(a) || /^(-[A-Za-z])(.+)$/s.exec(a);
    const flag = m && known.includes(m[1]) ? m[1] : a;
    const inline = flag === a ? undefined : m[2];
    if (flags.method.includes(flag)) method = String(inline ?? argv[++i]?.text ?? '').toUpperCase();
    else if (flags.body.includes(flag)) {
      body = true;
      const v = inline ?? argv[++i]?.text ?? '';
      // A GraphQL query may come from a file: -F query=@q.graphql or --input q.json.
      const file = /^(?:[\w.-]+=)?@(.+)$/s.exec(v)?.[1] ?? (flag === '--input' ? v : null);
      let content = '';
      try { if (file && file !== '-') content = readFileSync(resolvePath(ctx.cwd, file), 'utf8').slice(0, 1 << 20); } catch {}
      text.push(v, content);
      fields.push(v);
    } else {
      text.push(a);
      urls.push(a);
    }
  }
  method ||= body ? 'POST' : 'GET';
  const graphql = urls.some((u) => /(^|\/)graphql\/?$/.test(u));
  if (cfg.blockMerges && graphql && /mergePullRequest|enablePullRequestAutoMerge|mergeBranch/i.test(text.join('\n'))) {
    return deny('a GraphQL merge mutation', MERGES);
  }
  if (cfg.blockMerges && method !== 'GET' && urls.some((u) => /(^|\/)pulls\/[^/\s]+\/merge(?![\w-])|(^|\/)merges(?![\w-])/.test(u))) {
    return deny(`a ${method} to a GitHub merge endpoint`, MERGES);
  }
  const ref = urls.map((u) => /(?:^|\/)git\/refs\/heads\/([^?#\s]+)/.exec(u)?.[1]).find(Boolean);
  if (ref && method === 'DELETE' && cfg.blockBranchDelete) return deny('a DELETE of a branch ref', DELETES);
  if (ref && method !== 'GET' && isProtected(ref, cfg)) return deny(`a ${method} to the ${ref} branch ref`, protectedWhy(ref));
  // The contents API commits a file change. Without a branch field it commits to the default branch.
  const contents = urls.some((u) => /(^|\/)repos\/[^/\s]+\/[^/\s]+\/contents(\/|$)/.test(u));
  const target = fields.map((f) => /^branch=(.*)$/s.exec(f)?.[1]).find((b) => b !== undefined);
  if (contents && method !== 'GET' && cfg.protectedBranches.length && (target === undefined || isProtected(target, cfg))) {
    const why = target === undefined ? 'with no branch field it commits to the default branch, usually a protected one.' : protectedWhy(target);
    return deny(`a commit through the contents API to ${target ?? 'the default branch'}`, why);
  }
  return null;
}

// Returns the deny reason, or null when the command may run.
export function check(command, { cwd = process.cwd(), config = loadConfig() } = {}) {
  try {
    return walk(parse(command), { cwd, config, allow: false, onBranch: new Map(), vars: new Map() }, 0);
  } catch (err) {
    if (err !== TOO_DEEP) throw err;
    return deny('a command nested too deeply to check', `past ${MAX_DEPTH} levels of $(...), sh -c or eval the hook stops reading.`);
  }
}

// True the first time `note` comes up in this session.
function firstTime(note, session, env) {
  const dir = env.CLAUDE_PLUGIN_DATA || tmpdir();
  const file = join(dir, `git-guardrails-${note}-${String(session || 'none').replace(/[^\w.-]/g, '_')}`);
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(file, '', { flag: 'wx' });
    return true;
  } catch (err) {
    return err.code !== 'EEXIST';
  }
}

// The hook's answer to one PreToolUse payload: a deny, a once-per-session note, or null.
export function respond(input, env = process.env) {
  try {
    const command = input?.tool_input?.command;
    if (typeof command !== 'string') return null;
    const cwd = typeof input.cwd === 'string' && input.cwd ? input.cwd : process.cwd();
    const reason = check(command, { cwd, config: loadConfig(env) });
    return reason && { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } };
  } catch (err) {
    const systemMessage = `git-guardrails let a command through after an internal error: ${err.message}`;
    return firstTime('error', input?.session_id, env) ? { systemMessage } : null;
  }
}

const isMain = () => {
  try { return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; }
};

if (isMain()) {
  let input = null;
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch {}
  const out = input && respond(input);
  if (out) process.stdout.write(`${JSON.stringify(out)}\n`);
}
