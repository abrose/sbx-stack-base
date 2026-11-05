#!/usr/bin/env node
// PreToolUse/Bash hook: deny bash commands chained into too many segments.
//
// Reads the hook payload on stdin, counts top-level command separators
// (; && || |) in tool_input.command, and denies the call when the count
// exceeds THRESHOLD so Claude is pushed to split the work into smaller,
// readable steps.
//
// Quoted strings and heredoc bodies are stripped before counting: a `|` in a
// markdown table inside a `glab mr create` heredoc, or a `;` inside an echoed
// string, is not a real command separator and must not trip the guard.

// Deny when the number of separators is GREATER than this (so >4 == 5+ segments).
const THRESHOLD = 4;

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
};

// Remove heredoc bodies: everything from the line after `<<DELIM` up to the
// closing delimiter line. Handles <<-, and quoted/unquoted delimiters.
const stripHeredocs = (cmd) => {
  const lines = cmd.split('\n');
  const out = [];
  let i = 0;
  const heredocStart = /<<-?\s*(["']?)([A-Za-z_][A-Za-z0-9_]*)\1/;
  while (i < lines.length) {
    const line = lines[i];
    out.push(line);
    const match = line.match(heredocStart);
    if (match) {
      const delimiter = match[2];
      i += 1;
      // Skip body lines until the delimiter (optionally indented for <<-).
      while (i < lines.length && lines[i].trim() !== delimiter) i += 1;
      // Drop the closing delimiter line too.
      if (i < lines.length) i += 1;
      continue;
    }
    i += 1;
  }
  return out.join('\n');
};

// Strip single- and double-quoted regions so separators inside them don't count.
const stripQuotes = (cmd) => {
  let result = '';
  let quote = null;
  for (let i = 0; i < cmd.length; i += 1) {
    const ch = cmd[i];
    if (quote) {
      if (ch === '\\' && quote === '"') {
        i += 1; // skip escaped char inside double quotes
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    result += ch;
  }
  return result;
};

// Count top-level separators: && and || as single tokens, plus ; and |.
const countSeparators = (cmd) => {
  const stripped = stripQuotes(stripHeredocs(cmd));
  const matches = stripped.match(/\|\||&&|[;|]/g);
  return matches ? matches.length : 0;
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

  const count = countSeparators(command);
  if (count <= THRESHOLD) process.exit(0);

  const reason =
    `Command too complex: ${count} chained segments (separators ; && || |, limit ${THRESHOLD}). ` +
    `Split it into multiple shorter Bash calls so each step is easy to read and verify ` +
    `(prefer the dedicated Read/Grep/Glob tools over chained shell where they fit).`;

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
