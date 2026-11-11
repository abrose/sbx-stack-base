#!/usr/bin/env bash
# The CLI tools from apt: the newest version of each package in apt-packages.txt.
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=layers/lib.sh
. /layers/lib.sh

apt-get update
xargs -a "$here/apt-packages.txt" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends
ln -sf /usr/bin/batcat /usr/local/bin/bat
ln -sf /usr/bin/fdfind /usr/local/bin/fd

while read -r package; do
  # shellcheck disable=SC2016
  version=$(dpkg-query -W -f '${Version}' "$package")
  record tools "$package" "$version"
done <"$here/apt-packages.txt"
