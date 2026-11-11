#!/usr/bin/env bash
# Copies the result of build.sh (/out of the build stage) into the image: Neovim, its config and its plugins.
set -euo pipefail
home=/home/agent

cp -a /out/opt/nvim /opt/nvim
ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim

install -o agent -g agent -d "$home/.config" "$home/.local" "$home/.local/share"
cp -a "/out$home/.config/nvim" "$home/.config/nvim"
cp -a "/out$home/.local/share/nvim" "$home/.local/share/nvim"

cat /out/versions.txt >>"$SBX_STACK/versions.txt"
