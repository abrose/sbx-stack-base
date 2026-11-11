#!/usr/bin/env bash
# Static checks of the seed: the repo files only, no Docker, no sbx.
set -euo pipefail

cd "$(dirname "$0")/.."
fails=0

check() {
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS $what"
  else
    echo "FAIL $what"
    fails=$((fails + 1))
  fi
}

absent() {
  local f
  for f in "$@"; do
    [ ! -e "$f" ] || return 1
  done
}

no_match() {
  ! grep -qE "$@"
}

dropped_files=(chezmoi herdr-splits vim-tmux-navigator wishes example extend-markdown-preview minuet gitlab dap-js vitest)
dropped_plugins='"(chezmoi\.vim|herdr-splits\.nvim|vim-tmux-navigator|markdown-preview\.nvim|minuet-ai\.nvim|gitlab\.nvim|neotest-vitest|nvim-dap-vscode-js)"'

check "managed settings: an object with 4 enabled plugins" \
  jq -e 'type == "object" and (.enabledPlugins | length) == 4 and all(.enabledPlugins[]; . == true)' \
  files/claude/managed-settings.json
check "nvim: the dropped plugin files are gone" \
  absent "${dropped_files[@]/#/files/nvim/lua/plugins/}"
check "nvim: the kept plugin files are there" \
  test -f files/nvim/lua/plugins/claudecode.lua -a -f files/nvim/lua/plugins/harpoon.lua
check "nvim: lazyvim.json and lazy-lock.json exist" test -f files/nvim/lazyvim.json -a -f files/nvim/lazy-lock.json
check "nvim: no language, dap, test, prettier or eslint extras except lang.git" \
  no_match '"lazyvim\.plugins\.extras\.(lang\.[a-z.]+|dap\.core|test\.core|formatting\.prettier|linting\.eslint)"' \
  <(jq -r '.extras[] | select(. != "lazyvim.plugins.extras.lang.git") | "\"" + . + "\""' files/nvim/lazyvim.json)
check "nvim: no reference to a dropped plugin" no_match -r 'minuet|chezmoi|herdr|tmux-navigator|gitlab|markdown-preview|wishes|vitest|dap-vscode' files/nvim/lua
check "nvim: no Mac-only command" no_match -r '"open"|pbcopy|pbpaste|osascript' files/nvim/lua
check "nvim: the lock has no plugin of the dropped files" \
  no_match "$dropped_plugins" files/nvim/lazy-lock.json
check "no Mac paths in files/" \
  no_match -r 'NVIM_APPNAME|/opt/homebrew|/Users/|Library/' files
check "zshrc: direnv hook" grep -q 'direnv hook zsh' files/zsh/zshrc
check "zshrc: worktrunk shell init" grep -q 'wt config shell init zsh' files/zsh/zshrc
check "zshrc: COLORTERM=truecolor" grep -q 'COLORTERM=truecolor' files/zsh/zshrc
check "zshrc: yazi y() and rr" grep -qE '^(function )?y\(\)' files/zsh/zshrc
check "zshrc: alias rr" grep -q 'alias rr=' files/zsh/zshrc
check "the Dockerfile runs verify.lua through run-lua" grep -qx 'RUN run-lua /tmp/verify.lua' Dockerfile
check "the kit files are gone" absent base.yaml base.dockerfile host/sync-from-mac.sh tests/sbxenv-nomkt.yaml \
  files/claude/settings.json

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
