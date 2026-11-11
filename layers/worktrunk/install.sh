#!/usr/bin/env bash
# worktrunk (wt, git-wt) from its newest release.
set -euo pipefail
# shellcheck source=layers/lib.sh
. /layers/lib.sh

name=worktrunk-aarch64-unknown-linux-musl
tmp=$(mktemp -d)
fetch_latest max-sixty/worktrunk "$name.tar.xz" "$tmp/wt.tar.xz"
tar -xJf "$tmp/wt.tar.xz" -C "$tmp"
install -m 755 "$tmp/$name/wt" "$tmp/$name/git-wt" /usr/local/bin/
rm -rf "$tmp"

version=$(wt --version)
record worktrunk wt "${version##* }"
