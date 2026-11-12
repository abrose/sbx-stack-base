#!/usr/bin/env bash
# lazygit from its newest release.
set -euo pipefail
# shellcheck source=layers/lib.sh
. /layers/lib.sh

repo=jesseduffield/lazygit
version=$(latest_version "$repo")
tmp=$(mktemp -d)
fetch_release "$repo" "$version" "lazygit_${version}_linux_arm64.tar.gz" "$tmp/lazygit.tar.gz"
tar -xzf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit
install -m 755 "$tmp/lazygit" /usr/local/bin/
rm -rf "$tmp"

lazygit --version >/dev/null
record lazygit lazygit "$version"
