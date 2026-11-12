#!/usr/bin/env bash
# lazydocker from its newest release.
set -euo pipefail
# shellcheck source=layers/lib.sh
. /layers/lib.sh

repo=jesseduffield/lazydocker
version=$(latest_version "$repo")
tmp=$(mktemp -d)
fetch_release "$repo" "$version" "lazydocker_${version}_Linux_arm64.tar.gz" "$tmp/lazydocker.tar.gz"
tar -xzf "$tmp/lazydocker.tar.gz" -C "$tmp" lazydocker
install -m 755 "$tmp/lazydocker" /usr/local/bin/
rm -rf "$tmp"

lazydocker --version >/dev/null
record lazydocker lazydocker "$version"
