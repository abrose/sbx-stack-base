#!/usr/bin/env node
// PreToolUse/Bash hook: deny force pushes and deletes that target a protected
// branch.
//
// Protected branches are main, master, and the remote's default branch (read
// from refs/remotes/<remote>/HEAD). A push is destructive when it forces
// (--force, -f, --force-with-lease, a +refspec), deletes (--delete, -d,
// :branch), or rewrites whole ref sets (--mirror, or --all/--branches with
// force).
//
// Permission rules only see the command text, so they miss a bare
// `git push --force-with-lease` while on main. This hook asks git instead: a
// HEAD/@ refspec or a push with no refspec resolves to the current branch and
// its upstream (or to remote.<name>.push when configured), in the directory the
// command actually runs in (payload cwd, any earlier cd/pushd, and `git -C`).
// Git aliases are expanded, shell aliases and `sh -c`/`eval` strings are
// re-parsed, and wrappers (env, command, exec, nohup, time, nice, timeout,
// sudo, xargs) are stripped. A destructive push whose target cannot be known
// (detached HEAD, refs fed by xargs) is denied. Plain pushes are never touched.
//
// This is a guardrail against accidental pushes, not a security boundary: a
// determined agent can still route around a text-level check.
//
// The deny holds even when a prompt is approved by mistake; Chebu runs such a
// push themselves (`! git push ...`).

import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { basename, isAbsolute, resolve } from 'node:path';

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
};

// Split a shell command into segments of words. Quotes and $(...) are kept
// inside one word; ; && || | & ( ) and newlines end a segment. This is not a
// full shell parser: it only has to find git invocations and their arguments.
const segmentsOf = (command) => {
  const segments = [];
  let words = [];
  let word = null;
  const endWord = () => {
    if (word !== null) words.push(word);
    word = null;
  };
  const endSegment = () => {
    endWord();
    if (words.length > 0) segments.push(words);
    words = [];
  };
  // Copy a $( ... ) span verbatim, honoring nested parens and quotes.
  const skipSubst = (start) => {
    let depth = 0;
    let quote = null;
    for (let i = start; i < command.length; i++) {
      const c = command[i];
      if (quote) {
        if (c === quote) quote = null;
      } else if (c === "'" || c === '"') quote = c;
      else if (c === '(') depth++;
      else if (c === ')' && --depth === 0) return i;
    }
    return command.length - 1;
  };

  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (c === '\\' && i + 1 < command.length) {
      word = (word ?? '') + command[++i];
    } else if (c === "'") {
      const end = command.indexOf("'", i + 1);
      const stop = end === -1 ? command.length : end;
      word = (word ?? '') + command.slice(i + 1, stop);
      i = stop;
    } else if (c === '"') {
      let text = '';
      for (i++; i < command.length && command[i] !== '"'; i++) {
        if (command[i] === '\\' && i + 1 < command.length) text += command[++i];
        else if (command[i] === '$' && command[i + 1] === '(') {
          const end = skipSubst(i + 1);
          text += command.slice(i, end + 1);
          i = end;
        } else text += command[i];
      }
      word = (word ?? '') + text;
    } else if (c === '$' && command[i + 1] === '(') {
      const end = skipSubst(i + 1);
      word = (word ?? '') + command.slice(i, end + 1);
      i = end;
    } else if (';&|()\n'.includes(c)) {
      endSegment();
    } else if (c === ' ' || c === '\t') {
      endWord();
    } else {
      word = (word ?? '') + c;
    }
  }
  endSegment();
  return segments;
};

const git = (dir, ...args) => {
  try {
    return execFileSync('git', ['-C', dir, ...args], {
      stdio: ['ignore', 'pipe', 'ignore'],
      encoding: 'utf8',
      timeout: 3000,
    }).trim();
  } catch {
    return null;
  }
};

const currentBranch = (dir) => git(dir, 'symbolic-ref', '--quiet', '--short', 'HEAD') || null;

const upstreamBranch = (dir, branch) => {
  const merge = git(dir, 'config', `branch.${branch}.merge`);
  return merge ? merge.replace(/^refs\/heads\//, '') : null;
};

const protectedBranches = (dir, remote) => {
  const names = new Set(['main', 'master']);
  const head = git(dir, 'symbolic-ref', '--quiet', '--short', `refs/remotes/${remote}/HEAD`);
  if (head && head.startsWith(`${remote}/`)) names.add(head.slice(remote.length + 1));
  return names;
};

// Parse `git push` arguments into the flags and positionals that matter here.
const parsePush = (args) => {
  const push = { force: false, del: false, mirror: false, all: false, repo: null, positionals: [] };
  const takesValue = new Set(['-o', '--push-option', '--receive-pack', '--exec', '--repo']);
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--') {
      push.positionals.push(...args.slice(i + 1));
      break;
    }
    if (arg === '--force' || arg.startsWith('--force-with-lease')) push.force = true;
    else if (arg === '--delete') push.del = true;
    else if (arg === '--mirror') push.mirror = true;
    else if (arg === '--all' || arg === '--branches') push.all = true;
    else if (arg.startsWith('--repo=')) push.repo = arg.slice('--repo='.length);
    else if (takesValue.has(arg)) {
      if (arg === '--repo') push.repo = args[i + 1] ?? null;
      i++;
    } else if (/^-[A-Za-z0-9]+$/.test(arg)) {
      if (arg.includes('f')) push.force = true;
      if (arg.includes('d')) push.del = true;
      if (arg.endsWith('o')) i++;
    } else if (!arg.startsWith('-')) push.positionals.push(arg);
  }
  return push;
};

// Why this push must be denied, or null when it is fine. viaXargs means xargs
// appends arguments read from stdin, so the real targets are unknowable.
const denialFor = (args, dir, viaXargs) => {
  const push = parsePush(args);
  let [remoteArg, ...refspecs] = push.repo ? [push.repo, ...push.positionals] : push.positionals;
  const branch = currentBranch(dir);
  const remote = remoteArg ?? (branch && git(dir, 'config', `branch.${branch}.remote`)) ?? 'origin';
  const guarded = protectedBranches(dir, remote);

  if (push.mirror) return '--mirror rewrites every ref on the remote, including protected branches';
  if (push.all && push.force) return 'a forced --all/--branches push includes protected branches';
  if (viaXargs && (push.force || push.del)) {
    return 'xargs supplies the push targets from stdin, so they cannot be checked';
  }
  // With no refspec on the command line, git falls back to remote.<name>.push.
  if (refspecs.length === 0 && !push.all) {
    const configured = git(dir, 'config', '--get-all', `remote.${remote}.push`);
    if (configured) refspecs = configured.split('\n').filter(Boolean);
  }

  // Each target: the remote branch it lands on (null = unresolvable), and
  // whether that landing is destructive.
  const targets = [];
  if (refspecs.length === 0) {
    if (!push.force) return null;
    if (!branch) return 'a force push from a detached HEAD has no resolvable target branch';
    targets.push({ dest: branch, destructive: true });
    const upstream = upstreamBranch(dir, branch);
    if (upstream) targets.push({ dest: upstream, destructive: true });
  }
  for (const spec of refspecs) {
    const plus = spec.startsWith('+');
    const body = plus ? spec.slice(1) : spec;
    const colon = body.indexOf(':');
    const src = colon === -1 ? body : body.slice(0, colon);
    let dest = colon === -1 ? body : body.slice(colon + 1);
    const deletion = push.del || (colon !== -1 && src === '');
    if (dest === 'HEAD' || dest === '@') dest = branch;
    if (dest !== null) dest = dest.replace(/^refs\/heads\//, '');
    targets.push({ dest, destructive: push.force || plus || deletion });
  }

  for (const { dest, destructive } of targets) {
    if (!destructive) continue;
    if (dest === null) return 'a force push of HEAD from a detached HEAD has no resolvable target branch';
    if (dest.includes('*')) return `the forced glob refspec '${dest}' covers protected branches`;
    if (guarded.has(dest)) return `it force-pushes or deletes the protected branch '${dest}' on '${remote}'`;
  }
  return null;
};

// Prefix commands that run the rest of the line as a command, each with the
// flags that take a separate value and the count of positionals before the
// wrapped command (timeout DURATION).
const WRAPPERS = {
  env: { valued: ['-u', '-C', '-S'] },
  command: { valued: [] },
  exec: { valued: ['-a'] },
  nohup: { valued: [] },
  time: { valued: [] },
  builtin: { valued: [] },
  nice: { valued: ['-n'] },
  timeout: { valued: ['-s', '-k', '--signal', '--kill-after'], positionals: 1 },
  sudo: { valued: ['-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-U', '-T'] },
  xargs: { valued: ['-I', '-n', '-P', '-L', '-l', '-d', '-E', '-e', '-s', '-a'] },
};
const SHELLS = new Set(['bash', 'sh', 'zsh', 'dash', 'ksh']);
const MAX_DEPTH = 5;
const TOO_DEEP = `the push is nested more than ${MAX_DEPTH} levels deep (aliases, sh -c, eval), too deep to check`;

const isAssignment = (word) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word);
const shellQuote = (word) => `'${word.replace(/'/g, `'\\''`)}'`;

// Strip env assignments and wrapper commands off the front of a segment.
const unwrap = (segment) => {
  let words = segment;
  let viaXargs = false;
  for (;;) {
    if (words.length > 0 && isAssignment(words[0])) {
      words = words.slice(1);
      continue;
    }
    const wrapper = WRAPPERS[basename(words[0] ?? '')];
    if (!wrapper) return { words, viaXargs };
    if (basename(words[0]) === 'xargs') viaXargs = true;
    let i = 1;
    while (i < words.length && (words[i].startsWith('-') || (words[0] === 'env' && isAssignment(words[i])))) {
      i += wrapper.valued.includes(words[i]) ? 2 : 1;
    }
    words = words.slice(i + (wrapper.positionals ?? 0));
  }
};

// Resolve a git invocation (the words after `git`) down to a push, following
// aliases, and return the denial reason for it.
const denialForGit = (args, dir, viaXargs, depth) => {
  let gitDir = dir;
  let i = 0;
  while (i < args.length && args[i].startsWith('-')) {
    const opt = args[i];
    if (opt === '-C') {
      gitDir = resolvePath(gitDir, args[i + 1] ?? '.');
      i += 2;
    } else if (['-c', '--git-dir', '--work-tree', '--namespace'].includes(opt)) i += 2;
    else i += 1;
  }
  const [sub, ...rest] = args.slice(i);
  if (sub === 'push') return denialFor(rest, gitDir, viaXargs);
  if (!sub) return null;
  const alias = git(gitDir, 'config', '--get', `alias.${sub}`);
  if (!alias) return null;
  if (depth >= MAX_DEPTH) return TOO_DEEP;
  if (alias.startsWith('!')) {
    const script = [alias.slice(1), ...rest.map(shellQuote)].join(' ');
    return denialForCommand(script, gitDir, depth + 1);
  }
  const expanded = segmentsOf(alias)[0] ?? [];
  return denialForGit([...expanded, ...rest], gitDir, viaXargs, depth + 1);
};

const resolvePath = (dir, path) => {
  const target = path === '~' || path.startsWith('~/') ? homedir() + path.slice(1) : path;
  return isAbsolute(target) ? target : resolve(dir, target);
};

// Walk the segments, tracking cd/pushd, and return the first denial reason.
// Shell -c strings, eval, and shell aliases recurse, bounded by MAX_DEPTH.
// Past the bound the hook fails closed: an unexpanded alias, or nested text
// that still mentions push, is denied rather than waved through unchecked.
const denialForCommand = (command, cwd, depth = 0) => {
  if (depth > MAX_DEPTH) return /\bpush\b/.test(command) ? TOO_DEEP : null;
  let dir = cwd || process.cwd();
  for (const segment of segmentsOf(command)) {
    const { words, viaXargs } = unwrap(segment);
    if (words.length === 0) continue;
    const name = basename(words[0]);
    let reason = null;
    if (name === 'cd' || name === 'pushd') {
      dir = resolvePath(dir, words[1] ?? '~');
    } else if (SHELLS.has(name)) {
      const flag = words.findIndex((w, idx) => idx > 0 && /^-[A-Za-z]*c[A-Za-z]*$/.test(w));
      if (flag !== -1 && words[flag + 1]) reason = denialForCommand(words[flag + 1], dir, depth + 1);
    } else if (name === 'eval') {
      reason = denialForCommand(words.slice(1).join(' '), dir, depth + 1);
    } else if (name === 'git') {
      reason = denialForGit(words.slice(1), dir, viaXargs, depth);
    }
    if (reason) return reason;
  }
  return null;
};

const main = async () => {
  let command = '';
  let cwd = '';
  try {
    const payload = JSON.parse(await readStdin());
    command = payload?.tool_input?.command ?? '';
    cwd = payload?.cwd ?? '';
  } catch {
    // Malformed payload: stay out of the way, let the call proceed.
    process.exit(0);
  }

  if (typeof command !== 'string' || command.length === 0) process.exit(0);
  const why = denialForCommand(command, cwd);
  if (!why) process.exit(0);

  const reason =
    `Refusing this git push: ${why}. Agents never force-push or delete ` +
    "main, master, or the remote's default branch. Push to a feature branch " +
    'instead, or ask Chebu to run this push themselves.';

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    }),
  );
  process.exit(0);
};

await main();
