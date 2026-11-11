#!/usr/bin/env bash
# yazi (yazi, ya) from its newest release, and its config.
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=layers/lib.sh
. /layers/lib.sh

name=yazi-aarch64-unknown-linux-gnu
tmp=$(mktemp -d)
fetch_latest sxyazi/yazi "$name.zip" "$tmp/yazi.zip"
unzip -q "$tmp/yazi.zip" -d "$tmp"
install -m 755 "$tmp/$name/yazi" "$tmp/$name/ya" /usr/local/bin/
rm -rf "$tmp"

install -o agent -g agent -d /home/agent/.config
cp -R "$here/config" /home/agent/.config/yazi
chown -R agent:agent /home/agent/.config/yazi

version=$(yazi --version | awk '/Version:/ {print $2}')
record yazi yazi "$version"
