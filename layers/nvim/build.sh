#!/usr/bin/env bash
# Step 2 of the build-only stage, after build-tools.sh: the LazyVim config, the plugins, the treesitter parsers and
# the Rust matcher of blink.cmp, written to /out. Rust and the tree-sitter CLI stay in the stage.
# /run/lazy-lock.json is the plugin lock that build.sh on the Mac hands in: each plugin in it gets its locked commit,
# a plugin that is not in it gets its newest commit. An empty lock ({}) gives every plugin its newest commit.
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=layers/lib.sh
. /layers/lib.sh
export VERSIONS=/out/versions.txt
home=/home/agent

# with_rust <command...>: runs the command as agent with cargo in the PATH.
with_rust() {
  as_agent env "PATH=$home/.cargo/bin:$PATH" "$@"
}

install -o agent -g agent -d "$home/.config"
cp -R "$here/config" "$home/.config/nvim"
chown -R agent:agent "$home/.config/nvim"
# lazy.nvim writes the lock again, and the secret mount is readable by root only.
install -o agent -g agent -m 644 /run/lazy-lock.json "$home/.config/nvim/lazy-lock.json"

# One nvim process for the plugins and the parsers: a quit during LazyVim's background parser installs leaves
# tree-sitter lock files, and a second process waits 30 s on each and fails.
# lazy.nvim itself does not follow the lock: the config clones its release branch (stable) before the lock is read.
with_rust nvim --headless "+Lazy! install" "+luafile /layers/nvim/install-parsers.lua" +qa
# blink.cmp keeps its library in lib/; target/ holds only cargo's build files (110 MB).
rm -rf "$home/.local/share/nvim/lazy/blink.cmp/target"
# The gate for the steps above: it fails the build when a plugin, a parser or the matcher is missing.
with_rust /layers/nvim/run-lua /layers/nvim/verify.lua

mkdir -p "/out$home/.config" "/out$home/.local/share"
cp -a "$home/.config/nvim" "/out$home/.config/nvim"
cp -a "$home/.local/share/nvim" "/out$home/.local/share/nvim"

plugins=$(jq -r 'to_entries[] | "\(.key) \(.value.commit[0:12])"' "$home/.config/nvim/lazy-lock.json")
while read -r name commit; do
  record nvim "$name" "$commit"
done <<<"$plugins"
