#!/usr/bin/env bash
# Builds sbx-stack-base:<VERSION>, loads it into sbx as a template and runs tests/check.sh on it. When the check
# fails, the last image that passed the check comes back.
#   build.sh                    updates nothing: only the layers whose files changed build again
#   build.sh --update           takes the newest version of everything, the Claude kit image included
#   build.sh --update <layer>…  takes the newest versions for the named layers (the folders in layers/)
#   build.sh --rollback         loads the image that passed the check before the last one
#   build.sh --bump <level> …   raises the version in VERSION when the check passes: major, minor, patch or none.
#                               With no --bump, build.sh asks for the level when stdin is a terminal.
#
# Three docker tags hold the state:
#   sbx-stack-base:<VERSION>  the image that is loaded into sbx
#   sbx-stack-base:good       the last image that passed the check; only a passed check or a rollback moves it
#   sbx-stack-base:previous   the image that was good before that one
set -euo pipefail

cd "$(dirname "$0")"
usage() {
  echo "usage: build.sh [--bump major|minor|patch|none] [--update [layer...]] | --rollback" >&2
  echo "layers: $(all_layers | tr '\n' ' ')" >&2
  exit 2
}

# bumped <version> <level>: prints the version after a bump of the level.
bumped() {
  local major minor patch
  IFS=. read -r major minor patch <<EOF
$1
EOF
  case "$2" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    none) echo "$1" ;;
  esac
}

# ask_level <version>: asks on the terminal which level this build bumps, and prints the level. Enter means none.
# It fails when the input ends with no answer.
ask_level() {
  local answer
  {
    echo "the version is $1. Which level does this build bump?"
    echo "  none   $1  (Enter)"
    echo "  patch  $(bumped "$1" patch)  the same parts in newer versions, or a fix"
    echo "  minor  $(bumped "$1" minor)  a new part: a tool, a plugin, a layer, a setting"
    echo "  major  $(bumped "$1" major)  a kit or a project file must change"
  } >&2
  while true; do
    printf 'level: ' >&2
    read -r answer || {
      printf '\nno answer: nothing is built\n' >&2
      return 1
    }
    case "${answer:-none}" in
      major | minor | patch | none)
        echo "${answer:-none}"
        return 0
        ;;
    esac
    echo "the level is one of: none, patch, minor, major" >&2
  done
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
level=""
if [ "${1:-}" = --bump ]; then
  case "${2:-}" in
    major | minor | patch | none) level=$2 ;;
    *) usage ;;
  esac
  shift 2
fi
case "${1:-}" in
  "") ;;
  --rollback)
    [ $# -eq 1 ] || usage
    [ -z "$level" ] || usage
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

# The version of this build: the level comes from --bump, or from an answer when stdin is a terminal. VERSION gets
# the new version only after the check passes.
old_version=$(cat VERSION 2>/dev/null || true)
echo "$old_version" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
  echo "VERSION must be x.y.z, and it is '$old_version'" >&2
  exit 1
}
version=$old_version
if [ "$rollback" -eq 0 ]; then
  if [ -z "$level" ]; then
    if [ -t 0 ]; then
      level=$(ask_level "$old_version") || exit 1
    else
      level=none
      echo "no --bump and no terminal: the version stays $old_version"
    fi
  fi
  version=$(bumped "$old_version" "$level")
fi
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

# newest_kit: prints the newest version tag (x.y.z) of the Claude kit image on Docker Hub.
newest_kit() {
  curl -fsS 'https://hub.docker.com/v2/repositories/docker/sbx-kit-claude/tags?page_size=100&ordering=last_updated' |
    jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
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

# The Claude kit image is the base of the image. Its tag "latest" can be behind its newest version tag, so an
# update of everything (and the first build) looks up the newest version tag. Every other build keeps the kit of
# the good image, which records it as a label.
kit=latest
if [ "$pull" -eq 1 ] || [ "$had_good" -eq 0 ]; then
  kit=$(newest_kit) || kit=""
  [ -n "$kit" ] || {
    echo "cannot find the newest Claude kit tag on Docker Hub" >&2
    exit 1
  }
else
  kit=$(docker image inspect "$good" --format '{{index .Config.Labels "sbx-stack.claude-kit"}}')
  [ -n "$kit" ] || kit=latest
fi

# Each layer has a refresh value, the time of its last update. The image records the values as labels. A layer
# that keeps the value of the good image comes from the build cache as the good image has it. A new value runs the
# layer again, so the layer takes its newest versions; the layers after it in the Dockerfile run again too.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
lock=$tmp/lazy-lock.json
options=(--platform linux/arm64 --secret "id=lazy-lock,src=$lock")
options+=(--build-arg "CLAUDE_KIT=$kit" --label "sbx-stack.claude-kit=$kit")
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

echo "$version" >VERSION
[ "$had_good" -eq 0 ] || docker tag "$good" "$previous"
docker tag "$tag" "$good"
docker image inspect "$tag" --format '{{.Size}}' | awk '{printf "size of %s: %.0f MB\n", "'"$tag"'", $1 / 1e6}'
echo "what $tag holds (layer, name, version):"
docker run --rm --entrypoint cat "$tag" /usr/local/share/sbx-stack/versions.txt
finished=1
