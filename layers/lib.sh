#!/usr/bin/env bash
# Helpers for the layer scripts. A script loads them with: . /layers/lib.sh

# fetch_latest <owner/repo> <asset> <file>: downloads an asset of the newest GitHub release.
fetch_latest() {
  curl -fsSLo "$3" "https://github.com/$1/releases/latest/download/$2"
}

# latest_version <owner/repo>: prints the version of the newest GitHub release, without the leading v.
# For a project that has the version in the names of its release assets.
latest_version() {
  local url version
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest") || return 1
  version=${url##*/tag/v}
  [ "$version" != "$url" ] && [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

# fetch_release <owner/repo> <version> <asset> <file>: downloads an asset of the release v<version>.
fetch_release() {
  curl -fsSLo "$4" "https://github.com/$1/releases/download/v$2/$3"
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
