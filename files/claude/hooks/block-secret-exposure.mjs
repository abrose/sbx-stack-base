#!/usr/bin/env node
// PreToolUse/Bash hook: deny bash commands that would write a plaintext secret
// into the transcript.
//
// The transcript store captures every command and its output verbatim, so a
// secret that reaches a command line or a command's stdout is logged forever -
// gitleaks only guards the commit boundary, one step too late. This hook moves
// the boundary earlier: it refuses the command before it runs, so the secret is
// never observed. Every pattern it blocks has a non-leaking equivalent named in
// the deny reason (an env reference, ~/.pgpass, or gopass into a variable).
//
// Two complementary layers:
//   1. Shape rules (in-process, no dependency): catch command *shapes* that will
//      expose a secret even though the command text contains no secret string -
//      a secret-named variable set to a literal, a bulk secret-dump command, or a
//      password inside a connection URL. A content scanner is structurally blind
//      to these because the secret is only in the future output.
//   2. Content detection (gitleaks): catch recognizable credential material
//      pasted into the command text (tokens, keys). gitleaks is the maintained,
//      battle-tested ruleset - far broader than a hand-rolled regex list and it
//      allowlists example keys, so it false-positives less. If gitleaks is not on
//      PATH (or errors/times out) the hook degrades to the shape rules rather
//      than failing a command; keep gitleaks installed for full coverage.
//
// Reads the hook payload on stdin, inspects tool_input.command, and denies when
// either layer fires. On a malformed payload or an empty command it stays out of
// the way (exit 0, no output) so it can never wedge a session.

import { spawnSync } from 'node:child_process';
import { gopassFindingAst } from './gopass-shell-ast.mjs';

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
};

// --- Layer 1: shape rules (in-process) ---------------------------------------

// Variable names that denote a secret. Embedded in a longer name too
// (GITHUB_TOKEN, DB_PASSWORD), matched case-insensitively.
const SECRET_NAME =
  '[A-Z0-9_]*(?:PGPASSWORD|MYSQL_PWD|PASSWORD|PASSWD|SECRET|TOKEN|' +
  'API[_-]?KEY|ACCESS[_-]?KEY|SECRET[_-]?KEY|PRIVATE[_-]?KEY|CLIENT[_-]?SECRET)[A-Z0-9_]*';

// A NAME=VALUE assignment (optionally `-e NAME=VALUE` / `--env NAME=VALUE`),
// capturing the raw value token: a double-quoted run, a single-quoted run, or a
// bare token up to the next unquoted separator. The leading class also allows
// `?` and `&` so secrets in URL query strings (?api_key=..., &token=...) match.
const ASSIGN_RE = new RegExp(
  '(?:^|[\\s;&|(?])(?:-e\\s+|--env[=\\s]+)?(' +
    SECRET_NAME +
    ')=("(?:[^"\\\\]|\\\\.)*"|\'[^\']*\'|[^\\s;&|]*)',
  'gim',
);

// A value is safe when it is empty or a shell reference (never a literal):
// $VAR, ${VAR}, $(...), or `...`.
const isReferenceOrEmpty = (raw) => {
  let v = raw.trim();
  if (
    (v.startsWith('"') && v.endsWith('"') && v.length >= 2) ||
    (v.startsWith("'") && v.endsWith("'") && v.length >= 2)
  ) {
    v = v.slice(1, -1);
  }
  v = v.trim();
  if (v === '') return true;
  return v.startsWith('$') || v.startsWith('`');
};

const inlineSecretLiteral = (cmd) => {
  ASSIGN_RE.lastIndex = 0;
  let m;
  while ((m = ASSIGN_RE.exec(cmd)) !== null) {
    if (!isReferenceOrEmpty(m[2])) {
      return `a literal value assigned to \`${m[1]}\``;
    }
  }
  return null;
};

// Commands whose stdout is a bulk dump of secrets.
const DUMP_PATTERNS = [
  [/\bdotnet\s+user-secrets\s+list\b/i, '`dotnet user-secrets list` prints every stored secret'],
  [/\bgh\s+auth\s+token\b/i, '`gh auth token` prints the GitHub token'],
  [/\bglab\s+config\s+get\b/i, '`glab config get` prints the stored GitLab token'],
  [
    /\bkubectl\s+get\s+secret\b[^|;&]*-o[=\s]*(?:yaml|json|jsonpath)/i,
    '`kubectl get secret -o yaml/json` prints the secret payload',
  ],
  [
    /\baws\s+secretsmanager\s+get-secret-value\b/i,
    '`aws secretsmanager get-secret-value` prints the secret',
  ],
  [
    /\baws\s+ssm\s+get-parameter\b[^|;&]*--with-decryption/i,
    '`aws ssm get-parameter --with-decryption` prints the decrypted value',
  ],
];

const dumpCommand = (cmd) => {
  for (const [re, label] of DUMP_PATTERNS) if (re.test(cmd)) return label;
  return null;
};

// A password embedded in a connection URL: scheme://user:PASSWORD@host. The
// password must be a literal - a leading $ or ` marks a reference and is allowed.
const URL_CRED_RE =
  /\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|rediss|amqp|amqps|https?|ftp|mssql):\/\/[^\s:/@]+:([^\s:/@$`][^\s:/@]*)@/i;

const urlCredential = (cmd) =>
  URL_CRED_RE.test(cmd) ? 'a literal password inside a connection URL (user:password@host)' : null;

// gopass is the sanctioned secret source, but only when its output lands in a
// variable or another command's arguments, never on stdout. The check runs on
// the command's executable text: literal text never
// runs, so single-quoted strings, the plain part of double-quoted strings, and
// quoted-delimiter heredoc bodies are dropped (commit messages, sed/perl
// programs and prose may mention gopass freely). $(...) and `...` inside double
// quotes do run, so they are kept.
const executableText = (cmd) => {
  let out = '';
  let heredoc = null;
  let i = 0;
  // Index just past the `)` that closes the `$(` whose `(` is at `open`.
  const substEnd = (open) => {
    let depth = 0;
    for (let j = open; j < cmd.length; j++) {
      if (cmd[j] === '(') depth++;
      else if (cmd[j] === ')' && --depth === 0) return j + 1;
    }
    return cmd.length;
  };
  while (i < cmd.length) {
    const c = cmd[i];
    if (c === '\\') {
      out += cmd.slice(i, i + 2);
      i += 2;
    } else if (c === "'") {
      const close = cmd.indexOf("'", i + 1);
      out += "''";
      i = close < 0 ? cmd.length : close + 1;
    } else if (c === '"') {
      out += '"';
      i++;
      while (i < cmd.length && cmd[i] !== '"') {
        if (cmd[i] === '\\') {
          i += 2;
        } else if (cmd[i] === '$' && cmd[i + 1] === '(') {
          const end = substEnd(i + 1);
          out += executableText(cmd.slice(i, end));
          i = end;
        } else if (cmd[i] === '`') {
          const close = cmd.indexOf('`', i + 1);
          const end = close < 0 ? cmd.length : close + 1;
          out += cmd.slice(i, end);
          i = end;
        } else {
          i++;
        }
      }
      out += '"';
      i++;
    } else if (c === '\n' && heredoc) {
      // Skip the quoted heredoc's body up to its delimiter line.
      const lines = cmd.slice(i + 1).split('\n');
      const bodyLines = lines.findIndex((line) => line.trim() === heredoc);
      if (bodyLines < 0) break;
      i += 1 + lines.slice(0, bodyLines + 1).join('\n').length;
      out += '\n';
      heredoc = null;
    } else {
      const quotedHeredoc = /^<<-?\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1/.exec(cmd.slice(i));
      if (quotedHeredoc) {
        heredoc = quotedHeredoc[2];
        out += '<<';
        i += quotedHeredoc[0].length;
      } else {
        out += c;
        i++;
      }
    }
  }
  return out;
};

// Commands that run a string argument as shell code, turning literal text back
// into executable text. For these, quotes are kept as command separators.
const REINTERPRET_RE =
  /\b(?:(?:ba|z|da|k)?sh\s+-c|eval|ssh|xargs|watch|herdr\s+pane\s+(?:run|send-text|send-keys)|tmux\s+send-keys)\b/;

// `$(gopass show ...)` with no second command, pipe or redirect inside. Its
// value goes into argv or a variable, not stdout, so it is safe unless the
// command around it prints its arguments.
const GOPASS_SUBST_RE = /\$\(\s*gopass\s+(?:show|cat)\b[^()&;|<>`]*\)/g;

// Commands that print their arguments, and declaration builtins, which print a
// value that is not a valid NAME=value in their error message.
const PRINTERS = new Set(['echo', 'printf', 'print', 'cat', 'tee', 'logger']);
const DECLARERS = new Set(['export', 'declare', 'typeset', 'local', 'readonly']);
// Words in front of the real command word: wrappers and shell keywords.
const PASSTHROUGH = new Set([
  'sudo', 'env', 'command', 'exec', 'time', 'nohup', 'nice',
  '!', '{', 'if', 'then', 'else', 'elif', 'do', 'while', 'until',
]);
const ASSIGN_WORD_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// `prefix` is the simple command's text in front of the substitution. Unsafe:
// a here-string, a printing command, the substitution as the command word
// itself (the shell runs the secret, and "command not found: <secret>" prints
// it), or a declaration builtin given the secret as a bare word.
const substitutionIsSafe = (prefix) => {
  if (/<<<\s*"?$/.test(prefix)) return false;
  const words = prefix.split(/\s+/);
  const ownWord = words.pop(); // the partial word the substitution sits in
  const assignment = /^[A-Za-z_][A-Za-z0-9_]*="?$/.test(ownWord);
  const commandWord = words.find((w) => w && !PASSTHROUGH.has(w) && !ASSIGN_WORD_RE.test(w));
  if (commandWord === undefined) return assignment;
  const name = commandWord.split('/').pop();
  if (PRINTERS.has(name)) return false;
  if (DECLARERS.has(name)) return assignment;
  return true;
};

// Drop every safe gopass substitution; unsafe ones stay for the call scan.
const stripSafeSubstitutions = (text) =>
  text.replace(GOPASS_SUBST_RE, (subst, offset, whole) => {
    const before = whole.slice(0, offset);
    const start = Math.max(...[';', '&', '|', '\n', '(', '`'].map((c) => before.lastIndexOf(c)));
    return substitutionIsSafe(before.slice(start + 1)) ? '' : subst;
  });

// gopass in command position (also behind sudo/env/xargs/... and NAME=value
// prefixes, or by path), capturing its arguments up to the end of the command.
const GOPASS_CALL_RE =
  /(?:^|[;&|(`\n])\s*(?:(?:sudo|env|command|exec|time|nohup|xargs)\s+(?:-\S+\s+)*)*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:\S*\/)?gopass(?=\s|$)([^;&|)`\n]*)/g;

// Subcommands that never print a secret. Bare `gopass` lists the store.
// Everything else (show, cat, otp, generate, a bare entry path, ...) can print
// one, so it is denied unless it is `gopass show` copying to the clipboard.
// Not `find`: on an exact name match it shows the entry.
const GOPASS_SAFE = new Set(['ls', 'list', 'sync', 'help', 'version', 'mounts', 'recipients']);
const GOPASS_CLIP = new Set(['-c', '--clip']);

// Not covered (a shape rule cannot follow data flow): a variable printed later,
// e.g. X="$(gopass show -o p)"; echo "$X", or a program that echoes its own
// arguments (curl -v with an auth header, a verbose debug flag).
const gopassPrint = (cmd) => {
  // A re-run string's quotes become separators *before* substitutions are
  // judged, so `bash -c 'echo $(gopass ...)'` is judged by `echo`, not `bash`.
  const text = stripSafeSubstitutions(
    REINTERPRET_RE.test(cmd) ? cmd.replace(/['"]/g, ';') : executableText(cmd),
  );
  for (const [, rawArgs] of text.matchAll(GOPASS_CALL_RE)) {
    const all = rawArgs.trim().split(/\s+/).filter(Boolean);
    const comment = all.findIndex((t) => t.startsWith('#'));
    const args = comment < 0 ? all : all.slice(0, comment);
    const sub = args.find((t) => !t.startsWith('-'));
    if (sub === undefined || GOPASS_SAFE.has(sub)) continue;
    if (sub === 'show' && args.some((t) => GOPASS_CLIP.has(t))) continue;
    return (
      `\`gopass ${sub}\` can print a secret; only gopass ${[...GOPASS_SAFE].join('/')}, ` +
      '`gopass show -c`, and "$(gopass show ...)" passed to a command that does not print it are allowed'
    );
  }
  return null;
};

// The gopass rule runs on a real shell parse (gopass-shell-ast.mjs). When shfmt
// is missing or cannot parse the command, it falls back to the regex rule above,
// which misses quoting and keyword tricks (warn-if-no-gitleaks.sh flags that).
const gopassFinding = (cmd) => {
  const fromAst = gopassFindingAst(cmd);
  return fromAst === undefined ? gopassPrint(cmd) : fromAst;
};

const shapeFinding = (cmd) =>
  inlineSecretLiteral(cmd) || dumpCommand(cmd) || urlCredential(cmd) || gopassFinding(cmd);

// --- Layer 2: content detection (gitleaks) -----------------------------------

// Pipe the command text through gitleaks. status 1 = leak found; status 0 =
// clean. Anything else - binary missing (ENOENT), timeout (null status), or an
// internal error - means gitleaks is unavailable, so we do NOT block on it and
// fall through to the shape rules. gitleaks' stdout may echo the secret, so it is
// captured into a variable and never printed.
const gitleaksFlagged = (cmd) => {
  const res = spawnSync('gitleaks', ['detect', '--pipe', '--no-banner'], {
    input: cmd,
    encoding: 'utf8',
    timeout: 2000,
  });
  return res.status === 1;
};

// --- entry point -------------------------------------------------------------

const main = async () => {
  let command = '';
  try {
    const payload = JSON.parse(await readStdin());
    command = payload?.tool_input?.command ?? '';
  } catch {
    process.exit(0);
  }

  if (typeof command !== 'string' || command.length === 0) process.exit(0);

  const finding =
    shapeFinding(command) ||
    (gitleaksFlagged(command) ? 'recognizable credential material (flagged by gitleaks)' : null);
  if (!finding) process.exit(0);

  const reason =
    `Blocked: this command would put a secret into the transcript - ${finding}. ` +
    `The transcript store logs commands and their output verbatim, so the secret would be ` +
    `captured in plaintext. Use a non-printing form instead: reference an env var ` +
    `(e.g. "$PGPASSWORD"), put DB passwords in ~/.pgpass (chmod 600), pull tokens with ` +
    `gopass into a variable (export X="$(gopass show -o path)"), and never print or paste a ` +
    `secret value. If you must materialise a secret, write it to a gitignored file and do not ` +
    `read it back.`;

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
