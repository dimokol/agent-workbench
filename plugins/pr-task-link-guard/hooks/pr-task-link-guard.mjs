// pr-task-link-guard: a Claude Code PreToolUse hook for the Bash tool that
// refuses `gh pr create` unless the PR body links a task.
// The link may appear anywhere in the command text (an inline --body, or a
// heredoc that writes the body file in the same command), or in the file
// passed to --body-file or read by --body "$(cat file)", relative to the
// session's working directory.
// A PR passes anyway when PR_TASK_LINK_GUARD_ALLOW=1 sits directly before gh pr create.
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ALLOW = 'PR_TASK_LINK_GUARD_ALLOW';

// Plugin option first, then the plain env var for hand-wired setups. Empty means unset.
export function loadConfig(env = process.env) {
  const get = (key) => {
    const k = key.toUpperCase();
    return (env[`CLAUDE_PLUGIN_OPTION_${k}`] || env[`PR_TASK_LINK_GUARD_${k}`] || '').trim();
  };
  return { pattern: get('task_link_pattern'), scope: get('repo_scope') };
}

// Splits a command line into simple commands ("segments") of words, the way the
// shell would after removing quotes. `raw` keeps $-expansions for re-parsing an
// sh -c string. Heredoc and here-string text goes to the segment's `stdin`.
export function parse(cmd) {
  return scan(cmd, 0, null).segs;
}

function scan(cmd, i, closer) {
  const segs = [];
  const heredocs = [];
  let seg;
  let word = null;
  let quote = null;
  let redirect = null;
  let depth = 0;
  const next = () => (seg = { words: [], stdin: '', subs: [] });
  const add = (text, raw = text) => {
    word ??= { text: '', raw: '' };
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
    if (quote === "'") {
      if (c === "'") quote = null;
      else add(c);
      continue;
    }
    if (c === '\\' && i + 1 < cmd.length) {
      const n = cmd[++i];
      if (n === '\n') continue; // a line continuation
      add(quote === '"' && !'$`"\\'.includes(n) ? `\\${n}` : n);
      continue;
    }
    if (c === '`' && closer === '`') break;
    if (c === '`' || (c === '$' && cmd[i + 1] === '(')) {
      const from = i;
      const sub = scan(cmd, i + (c === '`' ? 1 : 2), c === '`' ? '`' : ')');
      seg.subs.push(...sub.segs);
      i = sub.i;
      add('$', cmd.slice(from, i + 1));
      continue;
    }
    if (quote === '"') {
      if (c === '"') quote = null;
      else add(c);
      continue;
    }
    if (c === "'" || c === '"') {
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
      if (op === '<<' || op === '<<-') {
        const d = /^[ \t]*((?:'[^']*'|"[^"]*"|\\.|[^\s;&|<>()])+)/.exec(cmd.slice(i + 1, i + 300));
        if (d) {
          heredocs.push({ seg, delim: d[1].replace(/['"\\]/g, ''), tabs: op === '<<-' });
          i += d[0].length;
        }
      } else redirect = op;
    } else if (c === '\n') {
      end();
      i = readHeredocs(cmd, i, heredocs);
    } else if (c === '(') {
      depth++;
      end();
    } else if (c === ')') {
      if (closer === ')' && depth === 0) break;
      depth--;
      end();
    } else if (c === ';' || c === '&' || c === '|') {
      end();
    } else add(c);
  }
  end();
  return { segs, i };
}

function readHeredocs(cmd, i, heredocs) {
  for (const h of heredocs.splice(0)) {
    while (i < cmd.length - 1) {
      const nl = cmd.indexOf('\n', i + 1);
      const stop = nl < 0 ? cmd.length : nl;
      const line = cmd.slice(i + 1, stop);
      i = stop;
      if ((h.tabs ? line.replace(/^\t+/, '') : line) === h.delim) break;
      h.seg.stdin += `${line}\n`;
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

const resolvePath = (base, p) => (p === '~' || p.startsWith('~/') ? join(homedir(), p.slice(1)) : resolve(base, p));

const valueOf = (args, short, long) => {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === short || args[i] === long) return args[i + 1];
    if (args[i].startsWith(`${long}=`)) return args[i].slice(long.length + 1);
  }
  return undefined;
};

// The word that holds --body's value: --body X, -b X or --body=X.
function bodyWord(words) {
  for (let k = 1; k < words.length; k++) {
    const t = words[k].text;
    if (t === '-b' || t === '--body') return words[k + 1];
    if (t.startsWith('--body=')) return { text: t.slice(7), raw: words[k].raw.replace(/^--body=/, '') };
  }
  return undefined;
}

// A body written "$(cat body.md)" comes from a file: the file's path, else undefined.
function catFile(word) {
  if (word?.text !== '$') return undefined;
  const m = /^\$\(([\s\S]*)\)$|^`([\s\S]*)`$/.exec(word.raw);
  const segs = m ? parse(m[1] ?? m[2]) : [];
  const w = segs.length === 1 ? segs[0].words.map((x) => x.text) : [];
  return w.length === 2 && w[0] === 'cat' ? w[1] : undefined;
}

// Collects every `gh pr create` in the command, with the cwd it runs in.
function findCreates(segs, ctx, depth, out) {
  if (depth > 10) return out;
  for (const seg of segs) {
    findCreates(seg.subs, { ...ctx, allow: false }, depth + 1, out);
    const { i, assigns } = skipPrefixes(seg.words);
    const allow = ctx.allow || assigns.includes(`${ALLOW}=1`);
    const envRepo = assigns.find((a) => a.startsWith('GH_REPO='))?.slice(8);
    const args = seg.words.slice(i).map((x) => x.text);
    const name = basename(args[0] ?? '');
    if (name === 'cd') {
      if (args[1] !== '-') ctx.cwd = resolvePath(ctx.cwd, args[1] ?? '~');
    } else if (SHELLS.has(name)) {
      findCreates(parse(shellScript(seg.words.slice(i), seg.stdin) ?? ''), { ...ctx, allow }, depth + 1, out);
    } else if (name === 'eval') {
      findCreates(parse(seg.words.slice(i + 1).map((x) => x.raw).join(' ')), { ...ctx, allow }, depth + 1, out);
    } else if (name === 'gh') {
      const [group, verb] = args.filter((a, k) => k > 0 && !a.startsWith('-') && args[k - 1] !== '-R' && args[k - 1] !== '--repo');
      if (group !== 'pr' || (verb !== 'create' && verb !== 'new')) continue; // gh ships `pr new` as an alias
      out.push({
        allow,
        cwd: ctx.cwd,
        web: args.includes('--web') || args.includes('-w'),
        repo: valueOf(args, '-R', '--repo') ?? envRepo,
        bodyFile: valueOf(args, '-F', '--body-file') ?? catFile(bodyWord(seg.words.slice(i))),
      });
    }
  }
  return out;
}

// owner/repo for every remote of the repo in `cwd`.
function remoteSlugs(cwd) {
  try {
    const opts = { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 3000 };
    return execFileSync('git', ['-C', cwd, 'remote', '-v'], opts)
      .split('\n')
      .map((line) => /[:/]([^/:\s]+\/[^/\s]+?)(?:\.git)?\/?\s/.exec(line)?.[1])
      .filter(Boolean);
  } catch {
    return [];
  }
}

function readBody(cwd, file) {
  // $PWD is the folder the command runs in and $HOME is known; other variables are not.
  const path = file
    ?.replace(/\$(?:\{PWD\}|PWD(?![A-Za-z0-9_]))/g, () => cwd)
    .replace(/\$(?:\{HOME\}|HOME(?![A-Za-z0-9_]))/g, () => homedir());
  if (!path || path === '-' || path.includes('$')) return '';
  try {
    return readFileSync(resolvePath(cwd, path), 'utf8').slice(0, 1 << 20);
  } catch {
    return '';
  }
}

// Returns { deny } to refuse the command, { note, message } to tell the user
// something once per session, or null to let it run.
export function decide(input, env = process.env) {
  const command = input?.tool_input?.command;
  if (typeof command !== 'string') return null;
  const cwd = typeof input.cwd === 'string' && input.cwd ? input.cwd : process.cwd();
  const creates = findCreates(parse(command), { cwd, allow: false }, 0, []).filter((c) => !c.allow && !c.web);
  if (!creates.length) return null;
  const cfg = loadConfig(env);
  const off = 'so PRs are not checked. Set it with /plugin configure, or PR_TASK_LINK_GUARD_TASK_LINK_PATTERN in a hand-wired setup.';
  if (!cfg.pattern) return { note: 'no-pattern', message: `pr-task-link-guard has no task_link_pattern, ${off}` };
  let link;
  let scope;
  try {
    link = new RegExp(cfg.pattern, 'i');
    scope = cfg.scope ? new RegExp(cfg.scope, 'i') : null;
  } catch (err) {
    return { note: 'bad-regex', message: `pr-task-link-guard can't use its config (${err.message}), so PRs are not checked.` };
  }
  if (link.test(command)) return null;
  for (const c of creates) {
    if (scope) {
      const slugs = c.repo ? [c.repo.split('/').slice(-2).join('/')] : remoteSlugs(c.cwd);
      if (!slugs.some((s) => scope.test(s))) continue;
    }
    if (link.test(readBody(c.cwd, c.bodyFile))) continue;
    return {
      deny:
        `pr-task-link-guard blocked gh pr create: the PR body has no task link (it must match /${cfg.pattern}/i). ` +
        'Find or create the task, put its link in the body (--body, or the file passed to --body-file), then run gh pr create again. ' +
        'A body file whose path uses a shell variable other than $PWD or $HOME cannot be read here, so write the literal path. ' +
        `Only if the user said this PR has no task, write ${ALLOW}=1 directly before gh pr create, not before cd or an earlier command in the chain.`,
    };
  }
  return null;
}

// True the first time `note` comes up in this session.
function firstTime(note, session, env) {
  const dir = env.CLAUDE_PLUGIN_DATA || tmpdir();
  const file = join(dir, `pr-task-link-guard-${note}-${String(session || 'none').replace(/[^\w.-]/g, '_')}`);
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
  let result;
  try {
    result = decide(input, env);
  } catch (err) {
    result = { note: 'error', message: `pr-task-link-guard let a command through after an internal error: ${err.message}` };
  }
  if (result?.deny) {
    return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: result.deny } };
  }
  return result?.note && firstTime(result.note, input?.session_id, env) ? { systemMessage: result.message } : null;
}

function isMain() {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  let input = null;
  try {
    input = JSON.parse(readFileSync(0, 'utf8'));
  } catch {}
  const out = input && respond(input);
  if (out) process.stdout.write(`${JSON.stringify(out)}\n`);
}
