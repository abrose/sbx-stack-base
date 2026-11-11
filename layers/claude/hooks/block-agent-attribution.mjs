#!/usr/bin/env node
// PreToolUse/Bash hook: deny commits, pull requests, and merge requests that
// carry agent attribution.
//
// Reads the hook payload on stdin and denies a `git commit`, `gh pr
// create|edit`, or `glab mr create|update` whose message or body carries any
// agent-attribution trailer:
//   - Co-Authored-By: a line naming Claude or anthropic (any model, any address)
//   - Claude-Session: ...
//   - 🤖 Generated with [Claude Code] ...
// so the agent's own attribution never lands in a commit, PR, or MR (see
// rules/git.md).
//
// The text arrives either inline in the command (a `-m`/`-b`/`-d` string or a
// quoted heredoc body) or from a file (`-F`/`--file`/`--body-file`/
// `--description-file`); both are inspected. A relative file path is resolved
// against the payload cwd. A command that only mentions a trailer without
// creating any of the above (git log --grep, gh pr view, echo) is left alone,
// because the deny requires an actual create/edit invocation. When a message
// file cannot be read, the hook stays out of the way and allows the call.

import { readFileSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';

const readStdin = async () => {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
};

// Commands that publish authored text: a git commit, a gh pull request, or a
// glab merge request being created or edited.
//
// git commit allows the global options that may precede the subcommand
// (git -C <dir> commit, git -c k=v commit).
const GIT_COMMIT = /\bgit\s+(?:-C\s+\S+\s+|-c\s+\S+\s+)*commit\b/;
const GH_PR = /\bgh\s+pr\s+(?:create|edit)\b/;
const GLAB_MR = /\bglab\s+mr\s+(?:create|update)\b/;

const publishesAuthoredText = (command) =>
  GIT_COMMIT.test(command) || GH_PR.test(command) || GLAB_MR.test(command);

// Agent-attribution trailers. Kept model-agnostic: a Co-Authored-By line is
// matched by the stable words Claude/anthropic, never a specific model name.
// The "Generated with" line appears both with markdown brackets
// (Generated with [Claude Code](...)) and as plain text (Generated with Claude
// Code), so the brackets are optional. The session link is caught both by its
// Claude-Session: label and, when it appears as a bare URL, by the
// claude.ai/code/session path itself.
const AGENT_TRAILERS = [
  /Co-Authored-By:.*(?:claude|anthropic)/i,
  /Claude-Session:/i,
  /Generated with \[?Claude Code\]?/i,
  /claude\.ai\/code\/session/i,
];

const hasAgentTrailer = (text) => AGENT_TRAILERS.some((re) => re.test(text));

// File paths passed via a body/message flag (attached, space-, or
// =-separated), with any surrounding quotes stripped:
//   - git commit:      -F / --file
//   - gh pr:           -F / --body-file
//   - glab mr:         --description-file
const messageFilePaths = (command) => {
  const paths = [];
  const patterns = [
    /(?:^|\s)-F\s*(\S+)/g,
    /(?:^|\s)--file[=\s]+(\S+)/g,
    /(?:^|\s)--body-file[=\s]+(\S+)/g,
    /(?:^|\s)--description-file[=\s]+(\S+)/g,
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(command)) !== null) {
      paths.push(match[1].replace(/^['"]|['"]$/g, ''));
    }
  }
  return paths;
};

const readMessageFile = (path, cwd) => {
  try {
    const full = isAbsolute(path) ? path : resolve(cwd || process.cwd(), path);
    return readFileSync(full, 'utf8');
  } catch {
    return '';
  }
};

const carriesAgentAttribution = (command, cwd) => {
  if (!publishesAuthoredText(command)) return false;
  if (hasAgentTrailer(command)) return true;
  return messageFilePaths(command).some((path) => hasAgentTrailer(readMessageFile(path, cwd)));
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
  if (!carriesAgentAttribution(command, cwd)) process.exit(0);

  const reason =
    'Refusing this command: the message or body carries agent attribution ' +
    '(a Co-Authored-By line naming Claude/Anthropic, a Claude-Session: line, ' +
    "or a 'Generated with [Claude Code]' line). Per rules/git.md, agent " +
    'attribution must never go into a commit, pull request, or merge request. ' +
    'Remove those trailer lines and try again.';

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
