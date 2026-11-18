#!/usr/bin/env bash
# Builds the image sbx-stack-base, loads it into sbx as a template and runs tests/check.sh on it. When the check
# fails, the last image that passed the check comes back.
#   build.sh                    updates nothing: only the layers whose files changed build again
#   build.sh --update           takes the newest version of everything, the Claude kit image included
#   build.sh --update <layer>…  takes the newest versions for the named layers (the folders in layers/)
#   build.sh --rollback         loads the image that passed the check before the last one
#   build.sh --load             loads the good image into sbx again: no build and no check
#   build.sh --bump <level> …   raises the version in VERSION when the check passes: major, minor, patch or none.
#                               With no --bump, build.sh asks for the level when stdin is a terminal.
#
# Four docker tags hold the state:
#   sbx-stack-base:<major>    the image that is loaded into sbx; project files name this tag
#   sbx-stack-base:<version>  the same image after a passed check; it shows the version in the list of templates
#   sbx-stack-base:good       the last image that passed the check; only a passed check or a rollback moves it
#   sbx-stack-base:previous   the image that was good before that one
#
# One file outside docker holds a copy of the good image: ~/.local/state/sbx-stack-base/good.tar (below
# XDG_STATE_HOME when it is set). A build loads it when docker has no good image, for example after
# "docker image prune -a".
#
# With the tool sbx-instance in PATH (the repo sbx-instances), each sbx instance on its list gets the template. The
# build, the first load and the check use plain sbx, so they run in the instance of this folder. After a passed
# check, each other instance gets the image with "sbx-instance run <name> -- template load". --load does the loads
# again: for a new instance, and after a load that failed.
set -euo pipefail

cd "$(dirname "$0")"
usage() {
  echo "usage: build.sh [--bump major|minor|patch|none] [--update [layer...]] | --rollback | --load" >&2
  echo "layers: $(all_layers | tr '\n' ' ')" >&2
  exit 2
}

# is_version <text>: true when the whole text is one version x.y.z, with no leading zero in a number. A text with
# more lines (a merge conflict in VERSION) is no version.
is_version() {
  local pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
  [[ $1 =~ $pattern ]]
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
load_only=0
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
  --load)
    [ $# -eq 1 ] || usage
    [ -z "$level" ] || usage
    load_only=1
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

# The targets of the template. others holds each sbx instance on the list of sbx-instance but the instance of this
# folder, which plain sbx uses. With no sbx-instance, plain sbx is the one target.
others=""
if command -v sbx-instance >/dev/null 2>&1; then
  instances=$(sbx-instance list) || {
    echo "sbx-instance list fails: nothing is built" >&2
    exit 1
  }
  here=$(sbx-instance which) || {
    echo "sbx-instance which names no sbx instance for the folder of build.sh (its message is above):" \
      "nothing is built" >&2
    exit 1
  }
  for name in $instances; do
    [ "$name" = "$here" ] || others="$others $name"
  done
fi
# A rollback over a major bump sets this to the newer major tag, which goes from each instance.
stale_major=""

# The version of this build: the level comes from --bump, or from an answer when stdin is a terminal. VERSION gets
# the new version only after the check passes.
old_version=$(cat VERSION 2>/dev/null || true)
is_version "$old_version" || {
  echo "VERSION must be x.y.z, and it is '$old_version'" >&2
  exit 1
}
version=$old_version
if [ "$rollback" -eq 0 ] && [ "$load_only" -eq 0 ]; then
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
# One image has two tags in docker and in sbx. Files name the major tag, so a bump of the minor or the patch level
# changes no file. The version tag shows the version in the list of templates; it comes after a passed check.
tag=sbx-stack-base:${version%%.*}
version_tag=sbx-stack-base:$version
old_tag=sbx-stack-base:${old_version%%.*}
good=sbx-stack-base:good
previous=sbx-stack-base:previous
# The path of the copy has one source. A variable that names another path would leave a copy at this path, older
# than the good image.
copy=${XDG_STATE_HOME:-$HOME/.local/state}/sbx-stack-base/good.tar
check=${SBX_STACK_CHECK:-tests/check.sh}
tmp=$(mktemp -d)

# When bash stops the script on an unset variable, it exits with the status of this trap, so the trap fails unless
# the script reached its end.
finished=0
passed_check=0
# others_started is 1 from the start of the loads into the other sbx instances. The instance of the folder has the
# image then, and VERSION holds its version. stop_again is the instance whose daemon a load has to stop again.
others_started=0
stop_again=""
cleanup() {
  rm -rf "$tmp"
  # A run that stopped during the save left a part of a file. The copy itself never has this name.
  rm -f "$copy.new" 2>/dev/null || true
  [ "$finished" -eq 0 ] || return 0
  [ -z "$stop_again" ] || stop_daemon "$stop_again"
  if [ "$others_started" -eq 1 ]; then
    # The same command again would raise the version a second time.
    echo "build.sh stopped during the loads into the other sbx instances. The image is good and" \
      "VERSION holds $(cat VERSION 2>/dev/null). Not each instance has the image. Run: build.sh --load" >&2
    exit 1
  fi
  # VERSION is the last thing that a build writes, so the same command gives the same version again.
  [ "$passed_check" -eq 0 ] ||
    echo "the check passed, but build.sh stopped before its end: VERSION is still $old_version." \
      "Run the same command again" >&2
  exit 1
}
trap cleanup EXIT

exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

image_id() {
  docker image inspect "$1" --format '{{.Id}}'
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

# save_copy: saves the good image to the copy file. The save goes to another name first, so the name of the copy
# never holds a part of a file.
save_copy() {
  mkdir -p "$(dirname "$copy")" && docker image save "$good" -o "$copy.new" && mv "$copy.new" "$copy"
}

# move_good <image>: the image is the good one from now on, and the copy outside docker holds it. The old copy goes
# before the tag moves: a copy that is older than the good image would give a later build the old refresh values, and
# so older versions of the tools with no message. A save that fails leaves no copy and does not stop the build.
move_good() {
  rm -f "$copy" "$copy.new"
  docker tag "$1" "$good"
  if ! save_copy; then
    rm -f "$copy.new"
    echo "cannot save $good to $copy: there is no copy of the good image now. The next passed build saves it again" >&2
  fi
}

# no_copy: there is no copy, and that is sure: nothing has the name of the copy, and the first folder above it
# that exists can be searched. A folder that cannot be searched hides whether the copy exists.
no_copy() {
  local dir
  if [ -e "$copy" ] || [ -L "$copy" ]; then
    return 1
  fi
  dir=$(dirname "$copy")
  while [ ! -e "$dir" ] && [ ! -L "$dir" ]; do
    dir=$(dirname "$dir")
  done
  [ -d "$dir" ] && [ -x "$dir" ]
}

# restore_good: when docker has no good image and the copy exists, loads the copy. A copy that does not give the
# good image stops the build: with no good image, the build would take the newest version of everything.
restore_good() {
  if exists "$good" || no_copy; then
    return 0
  fi
  # "No good image" can also mean that docker is down. Then the copy is not the cause.
  docker version >/dev/null 2>&1 || {
    echo "docker does not answer: nothing is built. Start docker, then run build.sh again" >&2
    exit 1
  }
  if [ ! -f "$copy" ] || [ ! -r "$copy" ]; then
    echo "docker has no $good image, and build.sh cannot read the copy $copy: nothing is built." \
      "The path is no file that build.sh can read, or a folder above it cannot be searched." \
      "Repair the path, or remove the copy: with no copy, the next build takes the newest version of everything" >&2
    exit 1
  fi
  if docker image load -i "$copy" >/dev/null && exists "$good"; then
    echo "docker had no $good image: restored $good from $copy"
    return 0
  fi
  echo "docker has no $good image, and cannot load it from $copy: nothing is built." \
    "If the file is broken, remove it: the next build then takes the newest version of everything" >&2
  exit 1
}

# load <tag>...: loads the image of the tags into sbx, as a template with each of the tags.
load() {
  docker image save "$@" -o "$tmp/image.tar"
  sbx template load "$tmp/image.tar"
}

# version_of <image>: prints the version that the image records in its version file.
version_of() {
  docker run --rm --entrypoint cat "$1" /usr/local/share/sbx-stack/VERSION | cut -d' ' -f1
}

# drop <tag>: removes the tag from sbx and from docker. A tag that does not exist is no error.
drop() {
  sbx template rm --force "$1" >/dev/null 2>&1 || true
  docker image rm "$1" >/dev/null 2>&1 || true
}

# version_tags: prints each version tag (sbx-stack-base:x.y.z) that docker or sbx holds.
version_tags() {
  local name
  {
    docker image ls sbx-stack-base --format '{{.Tag}}'
    sbx template ls --json | jq -r '.[] | select(.repository | test("(^|/)sbx-stack-base$")) | .tag'
  } | sort -u | while read -r name; do
    ! is_version "$name" || echo "sbx-stack-base:$name"
  done
}

# drop_other_versions <tag>: removes each version tag but this one, so one version tag exists at a time. The list
# comes from docker and from sbx, not from VERSION: a build that stopped, or a change of VERSION by hand, can leave
# a version tag that VERSION does not name.
drop_other_versions() {
  local list stale
  list=$(version_tags)
  for stale in $list; do
    [ "$stale" = "$1" ] || drop "$stale"
  done
}

# daemon_stopped <answer of "sbx daemon status">: true when the daemon does not run. Only the first Status line
# counts: a later line can be the state of a part of the daemon.
daemon_stopped() {
  local value
  value=$(sed -n -e '/^ *Status:/{' -e 's/^ *Status: *//p' -e 'q' -e '}' <<<"$1")
  [ "${value%"${value##*[![:space:]]}"}" = stopped ]
}

# stop_daemon <instance>: stops the daemon of the instance, unless a sandbox runs in it. A load takes about a
# minute, and a person can start a sandbox in that time. A list that sbx does not give counts as no sandbox.
stop_daemon() {
  local list
  list=$(sbx-instance run "$1" -- --no-input ls --json 2>/dev/null) || list=""
  if [ "$(jq -r 'if type == "array" then any(.[]; .status != "stopped") else false end' <<<"$list" 2>/dev/null)" = true ]
  then
    echo "the daemon of the instance $1 stays running: it did not run before the load, but a sandbox runs in it now" >&2
    return 0
  fi
  sbx-instance run "$1" -- --no-input daemon stop >/dev/null 2>&1 || true
}

# load_into <instance> <version tag>: loads the saved image $tmp/others.tar into another sbx instance and removes
# each other version tag there. A daemon that did not run before the load is stopped again, so a build leaves the
# daemons as it found them. An instance that is not signed in gets no image: a typing error in the list of
# sbx-instance is such an instance, as each sbx call creates the instance of its name.
load_into() {
  local name=$1 keep=$2 state list stale failed=0
  state=$(sbx-instance run "$name" -- --no-input daemon status 2>/dev/null) || state=""
  ! daemon_stopped "$state" || stop_again=$name
  if ! sbx-instance run "$name" -- --no-input ls >/dev/null 2>&1; then
    echo "the instance $name is not signed in to Docker, so it gets no image. If '$name' is a typing error in the" \
      "list of sbx-instance, correct the list. Else run: sbx-instance run $name -- login, then: build.sh --load" >&2
    failed=1
  elif sbx-instance run "$name" -- --no-input template load "$tmp/others.tar"; then
    if list=$(sbx-instance run "$name" -- --no-input template ls --json |
      jq -r '.[] | select(.repository | test("(^|/)sbx-stack-base$")) | .tag'); then
      for stale in $list; do
        if is_version "$stale" && [ "sbx-stack-base:$stale" != "$keep" ]; then
          sbx-instance run "$name" -- --no-input template rm --force "sbx-stack-base:$stale" >/dev/null 2>&1 || true
        fi
      done
      [ -z "$stale_major" ] ||
        sbx-instance run "$name" -- --no-input template rm --force "$stale_major" >/dev/null 2>&1 || true
    else
      echo "cannot list the templates of the instance $name: an older version tag can stay there" >&2
      failed=1
    fi
  else
    failed=1
  fi
  if [ -n "$stop_again" ]; then
    stop_daemon "$name"
    stop_again=""
  fi
  return "$failed"
}

# load_others <version tag> <tag>...: saves the image of the tags and loads it into each other sbx instance, one
# after the other. A load that fails does not stop the next one: the function fails at its end and names the
# instances that did not get the image.
load_others() {
  local keep=$1 name missing=""
  shift
  [ -n "$others" ] || return 0
  others_started=1
  if ! docker image save "$@" -o "$tmp/others.tar"; then
    echo "cannot save $* for the other sbx instances:$others. Then run: build.sh --load" >&2
    return 1
  fi
  for name in $others; do
    if load_into "$name" "$keep"; then
      echo "loaded $* into the instance $name"
    else
      echo "cannot load $* into the instance $name" >&2
      missing="$missing $name"
    fi
  done
  rm -f "$tmp/others.tar"
  [ -z "$missing" ] || {
    echo "the template is not in each sbx instance. Not loaded:$missing." \
      "Repair the instance (sbx-instance check), then run: build.sh --load" >&2
    return 1
  }
}

if [ "$rollback" -eq 1 ]; then
  exists "$previous" || {
    echo "there is no $previous image to roll back to" >&2
    exit 1
  }
  # The previous image comes back with its own version: under its major tag and its version tag.
  version=$(version_of "$previous") || version=""
  is_version "$version" || {
    echo "cannot read the version of $previous: nothing is changed" >&2
    exit 1
  }
  tag=sbx-stack-base:${version%%.*}
  version_tag=sbx-stack-base:$version
  docker tag "$previous" "$tag"
  docker tag "$previous" "$version_tag"
  load "$tag" "$version_tag"
  drop_other_versions "$version_tag"
  if [ "$old_tag" != "$tag" ]; then
    drop "$old_tag"
    echo "removed $old_tag: a file that names it must name $tag again" >&2
  fi
  echo "$version" >VERSION
  move_good "$previous"
  echo "loaded the image that was good before the last one as $tag and $version_tag"
  [ "$old_tag" = "$tag" ] || stale_major=$old_tag
  others_failed=0
  load_others "$version_tag" "$tag" "$version_tag" || others_failed=1
  finished=1
  exit "$others_failed"
fi

if [ "$load_only" -eq 1 ]; then
  restore_good
  exists "$good" || {
    echo "there is no $good image to load: run build.sh with no --load first" >&2
    exit 1
  }
  # The good image goes into sbx under its own version: its major tag and its version tag. VERSION stays.
  version=$(version_of "$good") || version=""
  is_version "$version" || {
    echo "cannot read the version of $good: nothing is loaded" >&2
    exit 1
  }
  tag=sbx-stack-base:${version%%.*}
  version_tag=sbx-stack-base:$version
  docker tag "$good" "$tag"
  docker tag "$good" "$version_tag"
  load "$tag" "$version_tag"
  drop_other_versions "$version_tag"
  echo "loaded the good image as $tag and $version_tag"
  others_failed=0
  load_others "$version_tag" "$tag" "$version_tag" || others_failed=1
  finished=1
  exit "$others_failed"
fi

restore_good
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

# The image records the commit of the repo. A build from files that are not committed gets a mark, so the record
# does not name a commit that does not hold these files.
revision=$(git rev-parse HEAD)
[ -z "$(git status --porcelain)" ] || revision=$revision+changes
# No provenance record: docker would add a record of the build, with its times, to the image, and the image id covers
# the record. Then a build with no change gives a new id, previous moves, and the image to roll back to is lost.
if ! docker build "${options[@]}" \
  --provenance=false \
  --build-arg GIT_USER_NAME="$(git config --global --get user.name || true)" \
  --build-arg GIT_USER_EMAIL="$(git config --global --get user.email || true)" \
  --build-arg VERSION="$version" \
  --build-arg REVISION="$revision" \
  --label org.opencontainers.image.revision="$revision" \
  -t "$tag" .; then
  echo "the build failed: the loaded template is unchanged" >&2
  exit 1
fi

load "$tag"
if ! SBX_STACK_VERSION=$version "$check"; then
  if [ "$tag" != "$old_tag" ]; then
    # A bump of the major level: the files still name the old major tag, and this build did not change it.
    drop "$tag"
    echo "the check failed: removed $tag; $old_tag is unchanged" >&2
  elif [ "$had_good" -eq 1 ]; then
    docker tag "$good" "$tag"
    load "$tag"
    echo "the check failed: restored the last image that passed the check" >&2
  else
    echo "the check failed: there is no earlier image to restore, so the failed $tag stays loaded" >&2
  fi
  exit 1
fi

# The check passed. The state tags move first: they are in docker only, so a rollback knows this image also when a
# later step fails. A build that gives the good image again (no change, or the same command after a stop) leaves
# previous as it is: else the image to roll back to is lost. VERSION comes last.
passed_check=1
if [ "$had_good" -eq 1 ] && [ "$(image_id "$good")" != "$(image_id "$tag")" ]; then
  docker tag "$good" "$previous"
fi
move_good "$tag"
docker tag "$tag" "$version_tag"
load "$version_tag"
drop_other_versions "$version_tag"
echo "$version" >VERSION
echo "the version is $version: the template is loaded as $tag and as $version_tag"
docker image inspect "$tag" --format '{{.Size}}' | awk '{printf "size of %s: %.0f MB\n", "'"$tag"'", $1 / 1e6}'
echo "what $tag holds (layer, name, version):"
docker run --rm --entrypoint cat "$tag" /usr/local/share/sbx-stack/versions.txt
# The other sbx instances come last: the image is good and VERSION holds its version, also when a load fails there.
others_failed=0
load_others "$version_tag" "$tag" "$version_tag" || others_failed=1
finished=1
[ "$others_failed" -eq 0 ] || exit 1
