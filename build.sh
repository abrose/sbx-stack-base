#!/usr/bin/env bash
# Builds sbx-stack-base:<VERSION> with the newest version of everything, loads it into sbx as a template and runs
# tests/check.sh on it. When the check fails, the last image that passed the check comes back.
# build.sh --rollback loads the image that passed the check before the last one.
#
# Three docker tags hold the state:
#   sbx-stack-base:<VERSION>  the image that is loaded into sbx
#   sbx-stack-base:good       the last image that passed the check; only a passed check or a rollback moves it
#   sbx-stack-base:previous   the image that was good before that one
set -euo pipefail

cd "$(dirname "$0")"
rollback=0
case "${1:-}" in
  "") ;;
  --rollback) rollback=1 ;;
  *)
    echo "usage: build.sh [--rollback]" >&2
    exit 2
    ;;
esac

version=$(cat VERSION)
tag=sbx-stack-base:$version
good=sbx-stack-base:good
previous=sbx-stack-base:previous
check=${SBX_STACK_CHECK:-tests/check.sh}
tmp=$(mktemp -d)

# When bash stops the script on an unset variable, it exits with the status of this trap, so the trap fails unless
# the script reached its end.
finished=0
cleanup() {
  rm -rf "$tmp"
  [ "$finished" -eq 1 ] || exit 1
}
trap cleanup EXIT

exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

load() {
  docker image save "$tag" -o "$tmp/image.tar"
  sbx template load "$tmp/image.tar"
}

if [ "$rollback" -eq 1 ]; then
  exists "$previous" || {
    echo "there is no $previous image to roll back to" >&2
    exit 1
  }
  docker tag "$previous" "$tag"
  load
  docker tag "$previous" "$good"
  echo "loaded the image that was good before the last one as $tag"
  finished=1
  exit 0
fi

had_good=0
if exists "$good"; then
  had_good=1
else
  echo "docker has no $good image: if the check of this build fails, build.sh cannot restore an earlier image" >&2
fi

revision=$(git rev-parse HEAD)
if ! docker build --pull --platform linux/arm64 \
  --build-arg REFRESH="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg GIT_USER_NAME="$(git config --global --get user.name || true)" \
  --build-arg GIT_USER_EMAIL="$(git config --global --get user.email || true)" \
  --build-arg VERSION="$version" \
  --build-arg REVISION="$revision" \
  --label org.opencontainers.image.revision="$revision" \
  -t "$tag" .; then
  echo "the build failed: the loaded template is unchanged" >&2
  exit 1
fi

load
if ! "$check"; then
  if [ "$had_good" -eq 1 ]; then
    docker tag "$good" "$tag"
    load
    echo "the check failed: restored the last image that passed the check" >&2
  else
    echo "the check failed: there is no earlier image to restore, so the failed $tag stays loaded" >&2
  fi
  exit 1
fi

[ "$had_good" -eq 0 ] || docker tag "$good" "$previous"
docker tag "$tag" "$good"
docker image inspect "$tag" --format '{{.Size}}' | awk '{printf "size of %s: %.0f MB\n", "'"$tag"'", $1 / 1e6}'
echo "what $tag holds (layer, name, version):"
docker run --rm --entrypoint cat "$tag" /usr/local/share/sbx-stack/versions.txt
finished=1
