// Shell-AST layer for the secret-exposure hook's gopass rule.
//
// Parses the command with shfmt (mvdan/sh, a bash-accurate parser) and judges
// every gopass use by its real place in the syntax tree, so quoting, escapes,
// keywords, functions and re-run strings cannot hide it the way they hide from
// a regex. The rule itself is unchanged:
//
//   - `gopass <sub>` as a command: allowed only for subcommands that never
//     print a secret, and `gopass show -c` (clipboard).
//   - `$(gopass show|cat ...)`: its value goes into a variable or argv, not
//     stdout, so it is allowed - except as an argument of a printing command,
//     in a here-string or heredoc body, as the command word itself (the shell
//     runs the secret and "command not found: <secret>" prints it), or as a
//     bare word to a declaration builtin.
//   - The string argument of a re-run command (sh -c, eval, ssh, herdr pane
//     run, ...) is parsed again and checked the same way.
//   - A computed command word ($G, $(which gopass), $'\x67...') in a command
//     that mentions gopass is denied: the real command cannot be known.
//
// gopassFindingAst returns a finding string, null when the command is clean,
// or undefined when shfmt is missing or cannot parse the command, so the
// caller falls back to its regex layer.
//
// Not covered: a variable printed later (X="$(gopass show p)"; echo "$X"), a
// program that echoes its own arguments (curl -v), a command word computed
// without the word gopass in the text (e.g. from base64), and a substitution
// that an unknown wrapper runs as a command (timeout 5 "$(gopass show p)").

import { basename, isAssignWord, literal, parse as parseWith, renderer, sourcer } from './shell-ast.mjs';

const SHFMT = process.env.SECRET_HOOK_SHFMT || 'shfmt';
const MAX_DEPTH = 4;

// Subcommands that never print a secret. Not `find`: on an exact name match it
// shows the entry.
const SAFE = new Set(['ls', 'list', 'sync', 'help', 'version', 'mounts', 'recipients']);
const CLIP = new Set(['-c', '--clip']);
const VALUE_SUBCOMMANDS = new Set(['show', 'cat']);

const PRINTERS = new Set(['echo', 'printf', 'print', 'cat', 'tee', 'logger']);
// Wrappers whose own command is the next word.
const WRAPPERS = new Set(['sudo', 'env', 'command', 'exec', 'time', 'nohup', 'nice', 'builtin']);
// Commands that run a string argument as shell code.
const RERUNNERS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'eval', 'ssh', 'xargs', 'watch', 'su', 'script', 'parallel']);

// Quotes, escapes and line continuations removed, so g''opass and \gopass still
// count as a mention. ANSI-C quoting ($'...') can spell any word, so it counts too.
const mentionsGopass = (code) =>
  code.replace(/\\\n/g, '').replace(/['"\\]/g, '').includes('gopass') || code.includes("$'");

// shfmt v3.13 and older write a redirect's Op as a number whose value differs
// between versions, so a non-string Op is judged as a here-string (fails closed).
const isHereString = (op) => op === '<<<' || typeof op !== 'string';

const parse = (code) => parseWith(code, SHFMT);

// --- the walk ----------------------------------------------------------------

// Every check returns a finding string or null.
const firstFinding = (items, fn) => {
  for (const item of items ?? []) {
    const found = fn(item);
    if (found) return found;
  }
  return null;
};

const gopassCall = (args) => {
  const words = args.map(literal);
  const sub = words.find((w) => w === null || !w.startsWith('-'));
  if (sub === undefined || (sub !== null && SAFE.has(sub))) return null;
  if (sub === null) return '`gopass` with a computed subcommand';
  if (sub === 'show' && words.some((w) => w !== null && CLIP.has(w))) return null;
  return `\`gopass ${sub}\` prints a secret to stdout`;
};

// The single `gopass show|cat ...` a substitution consists of, if that is all it is.
const valueGopass = (subst) => {
  const stmts = subst.Stmts ?? [];
  if (stmts.length !== 1) return null;
  const [stmt] = stmts;
  if (stmt.Redirs?.length || stmt.Negated || stmt.Background) return null;
  const cmd = stmt.Cmd;
  if (cmd?.Type !== 'CallExpr' || cmd.Assigns?.length) return null;
  const words = (cmd.Args ?? []).map(literal);
  if (words[0] === null || words[0] === undefined || basename(words[0]) !== 'gopass') return null;
  const sub = words.slice(1).find((w) => w === null || !w.startsWith('-'));
  return VALUE_SUBCOMMANDS.has(sub) ? sub : null;
};

// Only ever runs on a command that mentions gopass (see gopassFindingAst).
const makeWalker = (src, depth) => {
  const source = sourcer(src);
  const render = renderer(source);

  // A word's text with its `$(gopass show|cat ...)` value substitutions cut out.
  const residue = (w) =>
    (w?.Parts ?? [])
      .map((part) => {
        if (part.Type === 'Lit' || (part.Type === 'SglQuoted' && !part.Dollar)) return part.Value ?? '';
        if (part.Type === 'DblQuoted') return residue(part);
        if (part.Type === 'CmdSubst' && valueGopass(part)) return '';
        return source(part);
      })
      .join('');
  // A computed word that may spell gopass ($(which gopass), $'\x67opass').
  const hidesGopass = (w) => literal(w) === null && mentionsGopass(residue(w));
  // G=gopass or G=$(which gopass): the name is stored for a later $G.
  const storesGopass = (w) => {
    const value = literal(w);
    return value === null ? hidesGopass(w) : basename(value) === 'gopass';
  };

  // role: 'assign' | 'arg' | 'print' | 'command' - where the word's value goes.
  const word = (w, role) => firstFinding(w?.Parts, (part) => wordPart(part, role));

  const wordPart = (part, role) => {
    if (part.Type === 'CmdSubst') return cmdSubst(part, role);
    if (part.Type === 'DblQuoted') return word(part, role);
    return node(part); // ParamExp defaults, ProcSubst, arithmetic, ...
  };

  const cmdSubst = (subst, role) => {
    const sub = valueGopass(subst);
    if (sub === null) return stmts(subst.Stmts);
    if (role === 'assign' || role === 'arg') return null;
    return role === 'command'
      ? `\`$(gopass ${sub})\` as a command word runs the secret, and the shell prints it in its error`
      : `\`$(gopass ${sub})\` is printed by the command around it`;
  };

  const assign = (a, role) =>
    (storesGopass(a.Value) ? 'the name gopass stored in a variable' : null) ||
    word(a.Value, role) || firstFinding(a.Array?.Elems, (e) => word(e.Value, role)) || node(a.Index);

  const rerun = (args) => {
    const codes = [...args.map(render), args.map(render).join(' ')];
    return firstFinding(codes, (code) => {
      if (!mentionsGopass(code)) return null;
      if (depth >= MAX_DEPTH) return 'gopass inside re-run strings nested too deep to check';
      const found = check(code, depth + 1);
      return found === undefined ? 'gopass inside a re-run string that does not parse' : found;
    });
  };

  const callExpr = (call) => {
    const fromAssigns = firstFinding(call.Assigns, (a) => assign(a, 'assign'));
    if (fromAssigns) return fromAssigns;

    const args = call.Args ?? [];
    let i = 0;
    // Step over wrappers, their flags and env-style assignments.
    while (i < args.length) {
      const name = literal(args[i]);
      if (name === null || !WRAPPERS.has(basename(name))) break;
      i++;
      while (i < args.length) {
        const next = literal(args[i]);
        if (isAssignWord(args[i])) {
          const found = word(args[i], 'assign');
          if (found) return found;
        } else if (next === null || !next.startsWith('-')) break;
        i++;
      }
    }
    if (i >= args.length) return null;

    const head = args[i];
    const rest = args.slice(i + 1);
    const name = literal(head);
    if (name === null) {
      const found = word(head, 'command') || firstFinding(rest, (w) => word(w, 'arg'));
      return found || 'a computed command word in a command that mentions gopass';
    }

    const cmd = basename(name);
    if (cmd === 'gopass') return gopassCall(rest) || firstFinding(rest, (w) => word(w, 'arg'));

    const restWords = rest.map(literal);
    const isRerun =
      RERUNNERS.has(cmd) ||
      (cmd === 'herdr' && restWords[0] === 'pane' && ['run', 'send-text', 'send-keys'].includes(restWords[1])) ||
      (cmd === 'tmux' && restWords[0] === 'send-keys');
    if (isRerun) return rerun(rest);

    // A gopass word anywhere in argv may be run by the command around it
    // (timeout, find -exec, stdbuf, ...): judge what follows it as a gopass call.
    // Fails closed, so `grep gopass src` is denied too.
    const at = restWords.findIndex((w) => w !== null && basename(w) === 'gopass');
    const fromInner = at === -1 ? null : gopassCall(rest.slice(at + 1));
    if (fromInner) return fromInner;
    if (rest.some(hidesGopass)) return 'a computed word that may spell gopass in the argv of another command';

    const role = PRINTERS.has(cmd) ? 'print' : 'arg';
    return firstFinding(rest, (w) => word(w, role));
  };

  const declClause = (decl) =>
    firstFinding(decl.Args, (a) => (a.Naked ? word(a.Value, 'print') : assign(a, 'assign')));

  const stmt = (s) => {
    // A here-string or a heredoc body is the command's stdin: printed by cat & co.
    const fromRedirs = firstFinding(
      s.Redirs,
      (r) => word(r.Word, isHereString(r.Op) ? 'print' : 'arg') || word(r.Hdoc, 'print'),
    );
    return fromRedirs || node(s.Cmd);
  };

  const stmts = (list) => firstFinding(list, stmt);

  // Any other node: walk its children. Stmt and word lists are recognised by shape.
  const node = (n) => {
    if (!n || typeof n !== 'object') return null;
    if (Array.isArray(n)) return firstFinding(n, node);
    if (n.Type === 'CallExpr') return callExpr(n);
    if (n.Type === 'DeclClause') return declClause(n);
    if (n.Type === 'CmdSubst') return cmdSubst(n, 'arg');
    if ('Cmd' in n) return stmt(n);
    if (n.Parts && !n.Type) return word(n, 'arg');
    return firstFinding(
      Object.entries(n).filter(([key]) => !['Pos', 'End', 'Position'].includes(key)),
      ([, child]) => node(child),
    );
  };

  return stmts;
};

const check = (code, depth) => {
  const ast = parse(code);
  if (!ast) return undefined;
  return makeWalker(code, depth)(ast.Stmts);
};

export const gopassFindingAst = (command) => (mentionsGopass(command) ? check(command, 0) : null);
