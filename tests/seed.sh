#!/usr/bin/env bash
# Static checks of the repo files only: no Docker, no sbx.
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

executable() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && [ -x "$f" ] || return 1
  done
}

no_file_named() {
  [ -z "$(find . -name "$1" -not -path './.git/*' -print -quit)" ]
}

no_match() {
  ! grep -qE "$@"
}

# count <number> <pattern> <file>
count() {
  [ "$(grep -c "$2" "$3")" -eq "$1" ]
}

lib_functions() {
  local f
  for f in fetch_latest clone_head record as_agent; do
    grep -q "^$f()" layers/lib.sh || return 1
  done
}

nvim_layer_in_dockerfile() {
  grep -q '/layers/nvim/build.sh' Dockerfile && grep -q '/layers/nvim/install.sh' Dockerfile
}

curl_fails_on_error() {
  ! grep -rhE '(^|[^a-z])curl ' layers --include='*.sh' | grep -vqE ' -[a-zA-Z]*f'
}

dropped_files=(chezmoi herdr-splits vim-tmux-navigator wishes example extend-markdown-preview minuet gitlab dap-js vitest)
nvim=layers/nvim/config

check "each layer has an executable install.sh" \
  executable layers/tools/install.sh layers/zsh/install.sh layers/git/install.sh layers/yazi/install.sh \
  layers/worktrunk/install.sh layers/claude/install.sh
check "lib.sh defines fetch_latest, clone_head, record and as_agent" lib_functions
check "plugins.txt names 2 marketplaces" count 2 '^marketplace ' layers/claude/plugins.txt
check "plugins.txt names 4 plugins" count 4 '^plugin ' layers/claude/plugins.txt
check "every curl in layers/ fails on an HTTP error" curl_fails_on_error
check "the old folders are gone" absent files nvim-build apt-packages.txt
check "the Dockerfile holds no commit ARG and no clone function" no_match '_COMMIT|clone\(\)' Dockerfile
check "managed settings: an object with 4 enabled plugins" \
  jq -e 'type == "object" and (.enabledPlugins | length) == 4 and all(.enabledPlugins[]; . == true)' \
  layers/claude/managed-settings.json
check "nvim: the dropped plugin files are gone" \
  absent "${dropped_files[@]/#/$nvim/lua/plugins/}"
check "nvim: the kept plugin files are there" \
  test -f $nvim/lua/plugins/claudecode.lua -a -f $nvim/lua/plugins/harpoon.lua
check "nvim: lazyvim.json exists" test -f $nvim/lazyvim.json
check "no lazy-lock.json in the repo" no_file_named lazy-lock.json
check "the Dockerfile holds no version number, no sha256 and no heredoc" \
  no_match '[0-9]+\.[0-9]+\.[0-9]+|sha256|<<' <(grep -v '^# syntax=' Dockerfile)
check "the nvim layer has an executable build.sh, install.sh and run-lua" \
  executable layers/nvim/build.sh layers/nvim/install.sh layers/nvim/run-lua
check "the nvim layer has verify.lua and install-parsers.lua" \
  test -f layers/nvim/verify.lua -a -f layers/nvim/install-parsers.lua
check "the Dockerfile runs the nvim layer's build.sh and install.sh" nvim_layer_in_dockerfile
check "the nvim build runs verify.lua through run-lua" grep -q 'run-lua /layers/nvim/verify.lua' layers/nvim/build.sh
check "nvim: no language, dap, test, prettier or eslint extras except lang.git" \
  no_match '"lazyvim\.plugins\.extras\.(lang\.[a-z.]+|dap\.core|test\.core|formatting\.prettier|linting\.eslint)"' \
  <(jq -r '.extras[] | select(. != "lazyvim.plugins.extras.lang.git") | "\"" + . + "\""' $nvim/lazyvim.json)
check "nvim: no reference to a dropped plugin" no_match -r 'minuet|chezmoi|herdr|tmux-navigator|gitlab|markdown-preview|wishes|vitest|dap-vscode' $nvim/lua
check "nvim: no Mac-only command" no_match -r '"open"|pbcopy|pbpaste|osascript' $nvim/lua
check "no Mac paths in layers/" \
  no_match -r 'NVIM_APPNAME|/opt/homebrew|/Users/|Library/' layers
check "zshrc: direnv hook" grep -q 'direnv hook zsh' layers/zsh/zshrc
check "zshrc: worktrunk shell init" grep -q 'wt config shell init zsh' layers/zsh/zshrc
check "zshrc: COLORTERM=truecolor" grep -q 'COLORTERM=truecolor' layers/zsh/zshrc
check "zshrc: yazi y() and rr" grep -qE '^(function )?y\(\)' layers/zsh/zshrc
check "zshrc: alias rr" grep -q 'alias rr=' layers/zsh/zshrc
check "the kit files are gone" absent base.yaml base.dockerfile host/sync-from-mac.sh tests/sbxenv-nomkt.yaml \
  layers/claude/settings.json

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
