#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook: the block-secret-exposure PreToolUse hook degrades silently
# when a dependency is missing - without gitleaks it has no content detection,
# without shfmt its gopass rule falls back from the shell-AST check to the weaker
# regex layer. Surface that loudly, once per session, so a missing dependency
# cannot quietly weaken the gate. (Named for gitleaks, its first dependency.)

missing=()
command -v gitleaks >/dev/null 2>&1 || missing+=("gitleaks (no content detection)")
command -v shfmt >/dev/null 2>&1 || missing+=("shfmt (gopass rule on the regex fallback)")

if ((${#missing[@]})); then
  list="$(printf '%s, ' "${missing[@]}")"
  printf '{"systemMessage":"⚠️  The secret-exposure hook is degraded - missing: %s. Install: brew install gitleaks shfmt"}\n' "${list%, }"
fi
