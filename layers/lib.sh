#!/usr/bin/env bash
# Helpers for the layer scripts. A script loads them with: . /layers/lib.sh

# fetch_latest <owner/repo> <asset> <file>: downloads an asset of the newest GitHub release.
fetch_latest() {
  curl -fsSLo "$3" "https://github.com/$1/releases/latest/download/$2"
}

# clone_head <url> <dir>: copies the newest commit of the default branch to the folder and prints the commit.
clone_head() {
  git clone -q --depth 1 "$1" "$2" &&
    git -C "$2" rev-parse --short=12 HEAD &&
    rm -rf "$2/.git"
}

# record <layer> <name> <version>: adds a line to the list of what the image holds.
record() {
  local file=${VERSIONS:-/usr/local/share/sbx-stack/versions.txt}
  mkdir -p "$(dirname "$file")"
  printf '%s %s %s\n' "$1" "$2" "$3" >>"$file"
}

# as_agent <command...>: runs the command as the user agent.
as_agent() {
  runuser -u agent -- env HOME=/home/agent "$@"
}
