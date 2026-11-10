#!/usr/bin/env bash
# Builds sbx-stack-base:<VERSION> and loads it into sbx as a template. --force replaces a loaded template of the
# same version.
set -euo pipefail

cd "$(dirname "$0")"
force=0
case "${1:-}" in
  "") ;;
  --force) force=1 ;;
  *)
    echo "usage: build.sh [--force]" >&2
    exit 2
    ;;
esac

version=$(cat VERSION)
tag=sbx-stack-base:$version
if [ "$force" -eq 0 ] && sbx template ls | awk 'NR > 1 {print $1 ":" $2}' | grep -qxF "docker.io/library/$tag"; then
  echo "$tag is loaded already; build.sh --force replaces it" >&2
  exit 1
fi

revision=$(git rev-parse HEAD)
docker build --platform linux/arm64 \
  --build-arg GIT_USER_NAME="$(git config --global --get user.name || true)" \
  --build-arg GIT_USER_EMAIL="$(git config --global --get user.email || true)" \
  --build-arg VERSION="$version" \
  --build-arg REVISION="$revision" \
  --label org.opencontainers.image.revision="$revision" \
  -t "$tag" .

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
docker image save "$tag" -o "$tmp/image.tar"
sbx template load "$tmp/image.tar"
docker image inspect "$tag" --format '{{.Size}}' | awk '{printf "size of %s: %.0f MB\n", "'"$tag"'", $1 / 1e6}'
