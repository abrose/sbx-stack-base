#!/usr/bin/env node
// PreToolUse/Bash hook: deny inline interpreter scripts - code passed on the
// command line (python3 -c, node -e, perl -pe, ...) or through stdin
// (python3 - <<EOF, cat x | node).
//
// Inline code cannot be reviewed the way a file can, so the permission
// classifier cannot judge it and asks every time. The deny reason steers
// Claude to the dedicated tools, to jq/sed/rg, or to a script file written
// with Write and then run.
//
// The command is parsed with shfmt (see shell-ast.mjs), so a mention inside a
// string (git commit -m "python3 -c ...") does not count, while code inside
// $(...), pipelines, loops and re-run strings (bash -c '...', eval) does.
//
// When shfmt is missing or cannot parse the command, the call is allowed: this
// is a convenience guard against permission prompts, not a security boundary.
//
// Not covered: interpreters behind a wrapper flag that takes a value
// (sudo -u root python3 -c), find -exec / xargs, and computed command words.

import { ASSIGN_WORD_RE, basename, literal, parse, renderer, sourcer } from './shell-ast.mjs';

const SHFMT = process.env.INLINE_HOOK_SHFMT || 'shfmt';
const MAX_DEPTH = 4;

// codeLetters: short flags that take inline code (also inside a cluster: -pe).
// valueLetters: short flags that take a value, attached or as the next word;
//   the rest of the cluster is that value (-MJSON, -i.bak).
// attachedOnly: the values are never the next word (perl: -pi -e).
// digitLetters: short flags whose optional value is the digits after them
//   (perl -l, -0777), so the -e in -lane is still seen.
// moduleLetters: run a named module, not inline code (python3 -m pytest).
// codeLong / valueLong: the same for long flags (--eval, --require x).
// stdinBare: with no script argument, the interpreter runs stdin as code.
// subcommandCode: the first positional words that mean inline code (deno eval).
const INTERPRETERS = [
  { re: /^(python|pypy)[0-9.]*$/, codeLetters: 'c', valueLetters: 'WXm', moduleLetters: 'm', stdinBare: true },
  {
    re: /^(node|nodejs|tsx|ts-node)$/,
    codeLetters: 'ep',
    valueLetters: 'rC',
    codeLong: ['--eval', '--print'],
    valueLong: ['--require', '--import', '--loader', '--experimental-loader', '--input-type', '--env-file', '--conditions'],
    stdinBare: true,
  },
  { re: /^bun$/, codeLetters: 'ep', valueLetters: 'r', codeLong: ['--eval', '--print'], valueLong: ['--preload', '--cwd'] },
  { re: /^deno$/, subcommandCode: [['eval'], ['run', '-']] },
  {
    re: /^perl[0-9.]*$/,
    codeLetters: 'eE',
    valueLetters: 'MmIixdC',
    digitLetters: 'l0',
    attachedOnly: true,
    stdinBare: true,
  },
  { re: /^ruby[0-9.]*$/, codeLetters: 'e', valueLetters: 'rIxCEFKTW0', stdinBare: true },
  { re: /^php[0-9.]*$/, codeLetters: 'rBRE', valueLetters: 'cdz', stdinBare: true },
  { re: /^lua[0-9.]*$/, codeLetters: 'e', valueLetters: 'l', stdinBare: true },
  { re: /^osascript$/, codeLetters: 'e', valueLetters: 'ls', stdinBare: true },
];

// Flags that only print and exit: the interpreter never reads a script.
const INFO_FLAGS = new Set(['--version', '-V', '-v', '--help', '-h']);

// Commands that run the command after their own flags.
const WRAPPERS = new Set(['sudo', 'env', 'command', 'exec', 'time', 'nohup', 'nice', 'builtin', 'timeout', 'stdbuf']);
// Tool runners: `uv run python -c ...`. null means the runner takes no subcommand.
const RUNNERS = {
  uv: 'run',
  poetry: 'run',
  pipenv: 'run',
  pdm: 'run',
  hatch: 'run',
  rye: 'run',
  conda: 'run',
  mise: 'exec',
  pnpm: 'exec',
  npx: null,
};
// Wrapper and runner flags whose value is the next word.
const VALUE_FLAGS = new Set([
  '-u', '-g', '-n', '-s', '-k', '-p', '-C',
  '--with', '--with-editable', '--with-requirements', '--python', '--project', '--directory',
  '--package', '--extra', '--group', '--env-file', '--index', '--from', '--name', '--prefix', '--cwd',
]);
// Shells that run the word after -c as code.
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh']);

const interpreterFor = (word) => INTERPRETERS.find((spec) => spec.re.test(basename(word)));

// The index after a run of flags (and the value words of VALUE_FLAGS).
const skipFlags = (words, i) => {
  while (i < words.length && words[i]?.startsWith('-')) {
    if (words[i] === '--') return i + 1;
    i += VALUE_FLAGS.has(words[i]) ? 2 : 1;
  }
  return i;
};

// The index of the real command word, past wrappers, runners and env assignments.
const commandIndex = (words) => {
  let i = 0;
  while (i < words.length) {
    const word = words[i];
    if (word === null) return i;
    if (ASSIGN_WORD_RE.test(word)) {
      i += 1;
      continue;
    }
    const name = basename(word);
    if (WRAPPERS.has(name)) {
      // command -v python3 looks the name up, it runs nothing.
      if (name === 'command' && ['-v', '-V'].includes(words[i + 1])) return words.length;
      i = skipFlags(words, i + 1);
      if (name === 'timeout') i += 1; // the duration
      continue;
    }
    const sub = RUNNERS[name];
    if (sub === null || (sub !== undefined && words[i + 1] === sub)) {
      i = skipFlags(words, i + (sub === null ? 1 : 2));
      continue;
    }
    return i;
  }
  return i;
};

// 'code', 'stdin', or null for an interpreter call with argument words `args`.
const inlineKind = (spec, args) => {
  const { codeLetters = '', valueLetters = '', digitLetters = '', moduleLetters = '' } = spec;
  const { codeLong = [], valueLong = [], attachedOnly } = spec;
  for (let i = 0; i < args.length; i++) {
    const word = args[i];
    if (word === null) return null; // computed: cannot know, stay out of the way
    if (word === '-') return 'stdin';
    if (word === '--') return args[i + 1] === '-' ? 'stdin' : null;
    if (INFO_FLAGS.has(word)) return null;
    if (word.startsWith('--')) {
      const flag = word.split('=')[0];
      if (codeLong.includes(flag)) return 'code';
      if (valueLong.includes(flag) && !word.includes('=')) i += 1;
      continue;
    }
    if (word.startsWith('-') && word.length > 1) {
      const letters = word.slice(1);
      for (let at = 0; at < letters.length; at++) {
        const letter = letters[at];
        if (codeLetters.includes(letter)) return 'code';
        if (moduleLetters.includes(letter)) return null;
        if (digitLetters.includes(letter)) {
          while (/[0-9]/.test(letters[at + 1] ?? '')) at++;
          continue;
        }
        if (valueLetters.includes(letter)) {
          if (at === letters.length - 1 && !attachedOnly) i += 1; // the value is the next word
          break;
        }
      }
      continue;
    }
    // The first positional word: a script file, or a subcommand.
    const rest = args.slice(i);
    const isCode = spec.subcommandCode?.some((prefix) => prefix.every((p, k) => rest[k] === p));
    return isCode ? 'code' : null;
  }
  return spec.stdinBare ? 'stdin' : null;
};

const describe = (name, kind) =>
  kind === 'code' ? `\`${name}\` with inline code` : `\`${name}\` reading its script from stdin`;

// The -c code of a shell call (bash -c, sh -lc), or null.
const shellCode = (args) => {
  for (let i = 0; i < args.length; i++) {
    const word = literal(args[i]);
    if (word === '-o' || word === '+o') {
      i += 1; // the option name: bash -o pipefail -c '...'
      continue;
    }
    if (word === null || !word.startsWith('-') || word.startsWith('--')) return null;
    if (word.slice(1).includes('c')) return args[i + 1] ?? null;
  }
  return null;
};

const firstFinding = (items, fn) => {
  for (const item of items ?? []) {
    const found = fn(item);
    if (found) return found;
  }
  return null;
};

const makeWalker = (src, depth) => {
  const render = renderer(sourcer(src));

  const rerun = (code) => (depth >= MAX_DEPTH ? null : check(code, depth + 1));

  const callExpr = (call) => {
    const args = call.Args ?? [];
    const words = args.map(literal);
    const i = commandIndex(words);
    const name = words[i];
    if (typeof name === 'string') {
      const rest = args.slice(i + 1);
      const spec = interpreterFor(name);
      const kind = spec && inlineKind(spec, rest.map(literal));
      if (kind) return describe(basename(name), kind);

      const cmd = basename(name);
      if (SHELLS.has(cmd)) {
        const code = shellCode(rest);
        const found = code && rerun(render(code));
        if (found) return found;
      }
      if (cmd === 'eval') {
        const found = rerun(rest.map(render).join(' '));
        if (found) return found;
      }
    }
    // Substitutions in assignments and arguments: x=$(python3 -c ...).
    return node(call.Assigns) || node(args);
  };

  // Any node: walk its children, judging every simple command on the way.
  const node = (n) => {
    if (!n || typeof n !== 'object') return null;
    if (Array.isArray(n)) return firstFinding(n, node);
    if (n.Type === 'CallExpr') return callExpr(n);
    return firstFinding(
      Object.entries(n).filter(([key]) => !['Pos', 'End', 'Position'].includes(key)),
      ([, child]) => node(child),
    );
  };

  return node;
};

// A finding string, null when the command is clean, or undefined when it does
// not parse.
const check = (code, depth) => {
  const ast = parse(code, SHFMT);
  if (!ast) return undefined;
  return makeWalker(code, depth)(ast.Stmts);
};

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
};

const reasonFor = (finding) => {
  const lines = [
    `Inline script blocked: ${finding}.`,
    'Inline code cannot be reviewed, so it triggers a permission prompt every time.',
    'Use instead: Read/Edit/Write/Grep/Glob for files, jq/yq for JSON and YAML, rg/sed/awk for text one-liners.',
    'If a script is really needed, write it to a file in the scratchpad directory with Write, then run that file.',
  ];
  if (finding.startsWith('`perl')) lines.push('Do not use perl at all: use the Edit tool, sed or awk.');
  return lines.join(' ');
};

const main = async () => {
  let command = '';
  try {
    const payload = JSON.parse(await readStdin());
    command = payload?.tool_input?.command ?? '';
  } catch {
    // Malformed payload: stay out of the way, let the call proceed.
    process.exit(0);
  }

  if (typeof command !== 'string' || command.length === 0) process.exit(0);

  const finding = check(command, 0);
  if (!finding) process.exit(0);

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reasonFor(finding),
      },
    }),
  );
  process.exit(0);
};

await main();
