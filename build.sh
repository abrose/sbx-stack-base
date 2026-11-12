#!/usr/bin/env bash
# Builds sbx-stack-base:<VERSION>, loads it into sbx as a template and runs tests/check.sh on it. When the check
# fails, the last image that passed the check comes back.
#   build.sh                    updates nothing: only the layers whose files changed build again
#   build.sh --update           takes the newest version of everything, the Claude kit image included
#   build.sh --update <layer>…  takes the newest versions for the named layers (the folders in layers/)
#   build.sh --rollback         loads the image that passed the check before the last one
#
# Three docker tags hold the state:
#   sbx-stack-base:<VERSION>  the image that is loaded into sbx
#   sbx-stack-base:good       the last image that passed the check; only a passed check or a rollback moves it
#   sbx-stack-base:previous   the image that was good before that one
set -euo pipefail

cd "$(dirname "$0")"
usage() {
  echo "usage: build.sh [--update [layer...] | --rollback]" >&2
  echo "layers: $(all_layers | tr '\n' ' ')" >&2
  exit 2
}

all_layers() {
  local script
  for script in layers/*/install.sh; do
    basename "$(dirname "$script")"
  done
}

# updates <layer>: true when this build takes the newest versions for the layer.
updates() {
  case " $update " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

rollback=0
pull=0
update=""
case "${1:-}" in
  "") ;;
  --rollback)
    [ $# -eq 1 ] || usage
    rollback=1
    ;;
  --update)
    shift
    if [ $# -eq 0 ]; then
      pull=1
      update=$(all_layers | tr '\n' ' ')
    fi
    for layer in "$@"; do
      case "$layer" in */* | .* | -* | "") usage ;; esac
      [ -f "layers/$layer/install.sh" ] || usage
      update="$update $layer"
    done
    ;;
  *) usage ;;
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

# read_lock: writes the plugin lock of the good image to $lock; fails when the lock is not a filled JSON object.
read_lock() {
  docker run --rm --entrypoint cat "$good" /home/agent/.config/nvim/lazy-lock.json >"$lock" &&
    jq -e 'type == "object" and length > 0' "$lock" >/dev/null
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

# Each layer has a refresh value, the time of its last update. The image records the values as labels. A layer
# that keeps the value of the good image comes from the build cache as the good image has it. A new value runs the
# layer again, so the layer takes its newest versions; the layers after it in the Dockerfile run again too.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
lock=$tmp/lazy-lock.json
options=(--platform linux/arm64 --secret "id=lazy-lock,src=$lock")
[ "$pull" -eq 0 ] || options=(--pull "${options[@]}")
nvim_refresh=$now
for layer in $(all_layers); do
  refresh=""
  if [ "$had_good" -eq 1 ] && ! updates "$layer"; then
    refresh=$(docker image inspect "$good" --format "{{index .Config.Labels \"sbx-stack.refresh.$layer\"}}")
  fi
  [ -n "$refresh" ] || refresh=$now
  [ "$layer" != nvim ] || nvim_refresh=$refresh
  options+=(--build-arg "REFRESH_$(echo "$layer" | tr 'a-z-' 'A-Z_')=$refresh")
  options+=(--label "sbx-stack.refresh.$layer=$refresh")
done

# The plugin lock of Neovim: a build that does not update nvim gets the lock of the good image, so each plugin keeps
# its commit and only a new plugin takes its newest one. An empty lock gives every plugin its newest commit.
echo '{}' >"$lock"
if [ "$nvim_refresh" != "$now" ]; then
  # A missing or broken lock must stop the build: with it, every plugin would take its newest commit.
  if ! read_lock; then
    echo "cannot read the plugin lock of $good: run build.sh --update nvim to build without it" >&2
    exit 1
  fi
fi

revision=$(git rev-parse HEAD)
if ! docker build "${options[@]}" \
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
