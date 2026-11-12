#!/usr/bin/env bash
# Step 1 of the build-only stage: the newest Neovim, tree-sitter CLI and Rust. Neovim goes to /out; the tree-sitter
# CLI and Rust stay in the stage for step 2 (build.sh). This step runs again only for an update of the nvim layer.
set -euo pipefail
# shellcheck source=layers/lib.sh
. /layers/lib.sh
export VERSIONS=/out/versions.txt

tmp=$(mktemp -d)
mkdir -p /opt/nvim /out/opt
fetch_latest neovim/neovim nvim-linux-arm64.tar.gz "$tmp/nvim.tar.gz"
tar -xzf "$tmp/nvim.tar.gz" -C /opt/nvim --strip-components=1
ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim
cp -a /opt/nvim /out/opt/nvim
fetch_latest tree-sitter/tree-sitter tree-sitter-linux-arm64.gz "$tmp/tree-sitter.gz"
gunzip -c "$tmp/tree-sitter.gz" >/usr/local/bin/tree-sitter
chmod 755 /usr/local/bin/tree-sitter

curl -fsSLo "$tmp/rustup-init.sh" https://sh.rustup.rs
chmod 755 "$tmp" "$tmp/rustup-init.sh"
as_agent sh "$tmp/rustup-init.sh" -y --profile minimal --default-toolchain stable
rm -rf "$tmp"

# As agent: root would leave files of its own in the home of agent, and step 2 runs nvim as agent.
read -r _ version _ < <(as_agent nvim --version)
record nvim nvim "$version"
read -r _ version _ < <(as_agent tree-sitter --version)
record nvim tree-sitter "$version"
read -r _ version _ < <(as_agent /home/agent/.cargo/bin/rustc --version)
record nvim rust "$version"
