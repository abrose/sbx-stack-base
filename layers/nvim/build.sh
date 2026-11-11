#!/usr/bin/env bash
# Runs in a build-only stage and writes its result to /out: the newest Neovim, the LazyVim plugins at their newest
# commit, the treesitter parsers and the Rust matcher of blink.cmp. Rust and the tree-sitter CLI stay in the stage.
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

tmp=$(mktemp -d)
mkdir -p /opt/nvim
fetch_latest neovim/neovim nvim-linux-arm64.tar.gz "$tmp/nvim.tar.gz"
tar -xzf "$tmp/nvim.tar.gz" -C /opt/nvim --strip-components=1
ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim
fetch_latest tree-sitter/tree-sitter tree-sitter-linux-arm64.gz "$tmp/tree-sitter.gz"
gunzip -c "$tmp/tree-sitter.gz" >/usr/local/bin/tree-sitter
chmod 755 /usr/local/bin/tree-sitter
rm -rf "$tmp"

curl -fsSLo /tmp/rustup-init.sh https://sh.rustup.rs
as_agent sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable

install -o agent -g agent -d "$home/.config"
cp -R "$here/config" "$home/.config/nvim"
chown -R agent:agent "$home/.config/nvim"

# One nvim process for the plugins and the parsers: a quit during LazyVim's background parser installs leaves
# tree-sitter lock files, and a second process waits 30 s on each and fails.
with_rust nvim --headless "+Lazy! install" "+luafile /layers/nvim/install-parsers.lua" +qa
# blink.cmp keeps its library in lib/; target/ holds only cargo's build files (110 MB).
rm -rf "$home/.local/share/nvim/lazy/blink.cmp/target"
# The gate for the steps above: it fails the build when a plugin, a parser or the matcher is missing.
with_rust /layers/nvim/run-lua /layers/nvim/verify.lua

mkdir -p /out/opt "/out$home/.config" "/out$home/.local/share"
cp -a /opt/nvim /out/opt/nvim
cp -a "$home/.config/nvim" "/out$home/.config/nvim"
cp -a "$home/.local/share/nvim" "/out$home/.local/share/nvim"

read -r _ version _ < <(nvim --version)
record nvim nvim "$version"
read -r _ version _ < <(tree-sitter --version)
record nvim tree-sitter "$version"
read -r _ version _ < <(with_rust rustc --version)
record nvim rust "$version"
plugins=$(jq -r 'to_entries[] | "\(.key) \(.value.commit[0:12])"' "$home/.config/nvim/lazy-lock.json")
while read -r name commit; do
  record nvim "$name" "$commit"
done <<<"$plugins"
