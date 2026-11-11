#!/usr/bin/env bash
# zsh as the login shell of agent, with oh-my-zsh, two plugins, the zshrc and the starship prompt.
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=layers/lib.sh
. /layers/lib.sh

plugins=$SBX_STACK/oh-my-zsh-custom/plugins
mkdir -p "$plugins"

commit=$(clone_head https://github.com/ohmyzsh/ohmyzsh.git "$SBX_STACK/oh-my-zsh")
record zsh oh-my-zsh "$commit"
commit=$(clone_head https://github.com/zdharma-continuum/fast-syntax-highlighting.git "$plugins/fast-syntax-highlighting")
record zsh fast-syntax-highlighting "$commit"
commit=$(clone_head https://github.com/Aloxaf/fzf-tab.git "$plugins/fzf-tab")
record zsh fzf-tab "$commit"

install -D -m 644 "$here/zshrc" "$SBX_STACK/zsh/zshrc"
install -m 644 "$here/starship.toml" "$SBX_STACK/starship.toml"
printf '\nsource %s/zsh/zshrc\n' "$SBX_STACK" >>/etc/zsh/zshrc

usermod -s /usr/bin/zsh agent
install -o agent -g agent -m 644 /dev/null /home/agent/.zshrc
install -o agent -g agent -d /home/agent/.config
