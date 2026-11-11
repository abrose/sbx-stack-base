#!/usr/bin/env bash
# The git aliases, and the git identity that build.sh passes from the Mac.
set -euo pipefail
here=$(dirname "$0")

install -D -m 644 "$here/aliases.gitconfig" "$SBX_STACK/git/aliases.gitconfig"
git config --system --add include.path "$SBX_STACK/git/aliases.gitconfig"

if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --system user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --system user.email "$GIT_USER_EMAIL"
fi
