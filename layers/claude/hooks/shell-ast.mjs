// Shared shfmt (mvdan/sh) helpers for the Bash hooks that judge a command by
// its syntax tree instead of a regex: parsing, static word values, and
// rendering a word back to the shell code a re-run command (sh -c, eval) sees.

import { spawnSync } from 'node:child_process';

export const ASSIGN_WORD_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// The AST of a bash command, or undefined when shfmt is missing or cannot
// parse it.
export const parse = (code, shfmt = 'shfmt') => {
  const res = spawnSync(shfmt, ['--to-json', '-ln', 'bash'], { input: code, encoding: 'utf8', timeout: 2000 });
  if (res.error || res.status !== 0 || !res.stdout) return undefined;
  try {
    return JSON.parse(res.stdout);
  } catch {
    return undefined;
  }
};

export const basename = (word) => word.split('/').pop();
export const unescape = (text) => text.replace(/\\(.)/gs, '$1');

// The static value of a word, or null when part of it is computed at run time.
// shfmt omits Value for an empty part (''), hence the ?? ''.
export const literal = (word) => {
  let out = '';
  for (const part of word?.Parts ?? []) {
    if (part.Type === 'Lit') out += unescape(part.Value ?? '');
    else if (part.Type === 'SglQuoted' && !part.Dollar) out += part.Value ?? '';
    else if (part.Type === 'DblQuoted') {
      const inner = literal(part);
      if (inner === null) return null;
      out += inner;
    } else return null;
  }
  return out;
};

export const isAssignWord = (word) => {
  const first = word?.Parts?.[0];
  return first?.Type === 'Lit' && ASSIGN_WORD_RE.test(first.Value);
};

// A node's source text. Positions are byte offsets.
export const sourcer = (src) => {
  const bytes = Buffer.from(src);
  return (node) => bytes.subarray(node.Pos.Offset, node.End.Offset).toString();
};

// A word as the shell code a re-run command would see: quotes resolved,
// expansions kept as their source text.
export const renderer = (source) => {
  const render = (word) =>
    (word?.Parts ?? [])
      .map((part) => {
        if (part.Type === 'Lit') return unescape(part.Value ?? '');
        if (part.Type === 'SglQuoted' && !part.Dollar) return part.Value ?? '';
        if (part.Type === 'DblQuoted') return render(part);
        return source(part);
      })
      .join('');
  return render;
};
