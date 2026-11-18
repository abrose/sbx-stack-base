#!/usr/bin/env bash
# Unit tests of build.sh. docker and sbx are stubs; SBX_STACK_CHECK replaces tests/check.sh.
# The docker stub keeps its image tags in a file, as "<ref> <image id>" lines, so a test can run build.sh several
# times in a row and ask which image each tag names.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
passed=0
cleanup() {
  rm -rf "$tmp"
  [ "$passed" -eq 1 ] || exit 1
}
trap cleanup EXIT

bin=$tmp/bin
work=$tmp/work
calls=$tmp/calls
state=$tmp/state
out=$tmp/out
fails=0
rc=0
mkdir -p "$bin" "$work"

cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_LOG"
# STUB_DOCKER_DOWN=1: docker does not answer, so each command fails.
if [ "${STUB_DOCKER_DOWN:-0}" -ne 0 ]; then
  echo "Cannot connect to the Docker daemon" >&2
  exit 1
fi
image_of() { awk -v ref="$1" '$1 == ref {print $2}' "$STUB_STATE"; }
untag() {
  grep -v "^$1 " "$STUB_STATE" >"$STUB_STATE.new" || true
  mv "$STUB_STATE.new" "$STUB_STATE"
}
case "$1 ${2:-}" in
  "image inspect")
    [ -n "$(image_of "$3")" ] || exit 1
    # STUB_LABEL is the value of every sbx-stack.refresh.<layer> label of every image.
    case "$*" in
      *sbx-stack.claude-kit*) echo "${STUB_KIT:-}" ;;
      *sbx-stack.refresh.*) echo "${STUB_LABEL:-}" ;;
      *'{{.Id}}'*) image_of "$3" ;;
      *) echo 1000000 ;;
    esac
    ;;
  "image ls")
    awk '{print $1}' "$STUB_STATE" | sed -n 's/^sbx-stack-base://p'
    ;;
  "image save")
    # The file of a save holds the id of its first image, so a test can ask which image a file holds.
    # STUB_SAVE_FAIL is a tag: the save of this tag leaves a part of a file and fails.
    ref=$3
    id=$(image_of "$ref")
    shift 3
    while [ $# -gt 1 ] && [ "$1" != -o ]; do shift; done
    # STUB_SAVE_KILL is a tag: build.sh gets a signal during the save of this tag, and the save goes on for a
    # moment. STUB_KILL_SIGNAL is the signal: KILL (a kill, a loss of power) when it is not set.
    if [ "$ref" = "${STUB_SAVE_KILL:-}" ]; then
      [ "${1:-}" != -o ] || echo partial >"$2"
      kill "-${STUB_KILL_SIGNAL:-KILL}" "$PPID"
      sleep 1
      exit 1
    fi
    if [ "$ref" = "${STUB_SAVE_FAIL:-}" ]; then
      [ "${1:-}" != -o ] || echo partial >"$2"
      exit 1
    fi
    [ "${1:-}" != -o ] || echo "$id" >"$2"
    ;;
  "image load")
    # The stub loads a file of its own save: the good tag gets the id in the file. An empty file gives no tag.
    # STUB_LOAD_FAIL=1 makes the load fail.
    [ "${STUB_LOAD_FAIL:-0}" -eq 0 ] || exit 1
    id=$(cat "$4")
    if [ -n "$id" ]; then
      untag sbx-stack-base:good
      echo "sbx-stack-base:good $id" >>"$STUB_STATE"
    fi
    ;;
  "image rm")
    [ -n "$(image_of "$3")" ] || exit 1
    untag "$3"
    ;;
  tag\ *)
    id=$(image_of "$2")
    [ -n "$id" ] || exit 1
    untag "$3"
    echo "$3 $id" >>"$STUB_STATE"
    ;;
  run\ *)
    case "$*" in
      # STUB_VERSION is the version that every image records in its version file; "fail" makes the read fail.
      *sbx-stack/VERSION*)
        [ "${STUB_VERSION:-0.2.0}" != fail ] || exit 1
        echo "${STUB_VERSION:-0.2.0} abc1234"
        ;;
      *lazy-lock.json*)
        [ "${STUB_LOCK:-ok}" != fail ] || exit 1
        [ "${STUB_LOCK:-ok}" != broken ] || exit 0
        echo '{"stub":"lock"}'
        ;;
    esac
    ;;
  build\ *)
    [ "${STUB_BUILD_FAIL:-0}" -eq 0 ] || exit 1
    while [ "$1" != -t ]; do
      case "$1" in id=lazy-lock,src=*) cp "${1#id=lazy-lock,src=}" "$STUB_STATE.lock" ;; esac
      shift
    done
    untag "$2"
    # STUB_BUILD_ID is the id of the image that the build gives; without it each build gives a new image.
    echo "$2 ${STUB_BUILD_ID:-built-$(wc -l <"$STUB_LOG" | tr -d ' ')}" >>"$STUB_STATE"
    ;;
esac
EOF
# The sbx stub answers the template list: STUB_TEMPLATES is a file with the list as JSON, "fail" makes the list fail,
# and without it the list is empty.
cat >"$bin/sbx" <<'EOF'
#!/usr/bin/env bash
echo "sbx $*" >>"$STUB_LOG"
case "$1 ${2:-}" in
  "template ls")
    [ "${STUB_TEMPLATES:-}" != fail ] || exit 1
    if [ -n "${STUB_TEMPLATES:-}" ]; then cat "$STUB_TEMPLATES"; else echo '[]'; fi
    ;;
esac
EOF
# The curl stub answers the tag list of the Claude kit image; STUB_TAGS=fail makes it fail.
cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
[ "${STUB_TAGS:-ok}" != fail ] || exit 22
echo '{"results":[{"name":"latest"},{"name":"2.1.99"},{"name":"2.1.316"},{"name":"2.1.314"},{"name":"2.2.0-rc1"}]}'
EOF
# A check that passes and records the version that build.sh gives to it.
cat >"$bin/check-env" <<'EOF'
#!/usr/bin/env bash
echo "${SBX_STACK_VERSION:-}" >"$CHECK_VERSION_FILE"
EOF
chmod +x "$bin/docker" "$bin/sbx" "$bin/curl" "$bin/check-env"

cp "$repo/build.sh" "$work/"
# The tests have their own version, so they do not depend on the version of the repo.
version=0.2.0
echo "$version" >"$work/VERSION"
for layer in tools zsh git worktrunk yazi lazygit lazydocker claude nvim; do
  mkdir -p "$work/layers/$layer"
  : >"$work/layers/$layer/install.sh"
done
git -C "$work" init -q
git -C "$work" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m test
# tag is the major tag, which files name. vtag is the version tag, which shows the version in the template list.
tag=sbx-stack-base:${version%%.*}
vtag=sbx-stack-base:$version
good=sbx-stack-base:good
previous=sbx-stack-base:previous
: >"$calls"
# The copy of the good image. Each run gets this path, so no test touches the copy of the owner. Its folder does not
# exist before the first save.
copy=$tmp/keep/sbx-stack-base/good.tar

# images <ref id>...: the images that exist before the next run. No copy of the good image exists.
images() {
  rm -f "$copy" "$copy.new"
  : >"$state"
  : >"$state.lock"
  while [ $# -gt 0 ]; do
    echo "$1 $2" >>"$state"
    shift 2
  done
}

image_of() { awk -v ref="$1" '$1 == ref {print $2}' "$state"; }

# a_copy <image id>: a copy of the good image exists, as the docker stub saves it. An empty id gives an empty file.
a_copy() {
  mkdir -p "$(dirname "$copy")"
  printf '%s' "$1" >"$copy"
}
copy_holds() { [ -f "$copy" ] && [ "$(cat "$copy")" = "$1" ]; }
no_copy() { [ ! -e "$copy" ] && [ ! -e "$copy.new" ]; }

# The PATH of a run has no sbx-instance of the person who runs the tests: a run has the tool only when its test
# puts the stub into PATH.
clean=""
rest=$PATH:
while [ -n "$rest" ]; do
  dir=${rest%%:*}
  rest=${rest#*:}
  [ -n "$dir" ] && [ ! -e "$dir/sbx-instance" ] || continue
  clean=${clean:+$clean:}$dir
done

# build <VAR=value>... -- <build.sh arguments>: runs build.sh with the stubs; sets rc, $calls and $out.
# stdin is not a terminal, so build.sh asks nothing, also when a person runs these tests in a terminal.
build() {
  local envs=("PATH=$bin:$clean" "STUB_LOG=$calls" "STUB_STATE=$state" "XDG_STATE_HOME=$tmp/keep")
  while [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  # A marker line, so "this run" starts after it and the image ids of the stub stay unique.
  echo "--- run" >>"$calls"
  rc=0
  env "${envs[@]}" "$BASH" "$work/build.sh" "$@" >"$out" 2>&1 </dev/null || rc=$?
}

# build_on_terminal <answer>... -- <build.sh arguments>: as build with a check that passes, but stdin is a terminal
# (from script) that gets one line for each answer and then the end of the input.
build_on_terminal() {
  local answers=""
  while [ "$1" != -- ]; do
    answers="$answers$1"$'\n'
    shift
  done
  shift
  echo "--- run" >>"$calls"
  rc=0
  typed "$answers" |
    env "PATH=$bin:$clean" "STUB_LOG=$calls" "STUB_STATE=$state" "XDG_STATE_HOME=$tmp/keep" SBX_STACK_CHECK=true \
      script -q /dev/null "$BASH" "$work/build.sh" "$@" >"$out" 2>&1 || rc=$?
}

# typed <text>: writes the text as a person does, with a wait before it and before the end of the input. When the
# text and the end come at once, script gives the end of the input to the terminal first (probe on macOS, 2026-11-15).
typed() {
  sleep 1
  printf '%s' "$1"
  sleep 1
}

version_is() { [ "$(cat "$work/VERSION")" = "$1" ]; }
set_version() { echo "$1" >"$work/VERSION"; }
# fresh: the state before a version case: version 0.2.0, an image that is loaded and good.
fresh() {
  set_version "$version"
  images "$tag" old "$vtag" old "$good" old
}

expect() {
  local what=$1
  shift
  if "$@"; then
    echo "PASS $what"
  else
    echo "FAIL $what"
    fails=$((fails + 1))
  fi
}

this_run() { awk '/^--- run$/ {text = ""; next} {text = text $0 "\n"} END {printf "%s", text}' "$calls"; }
called() { this_run | grep -qF -- "$1"; }
not_called() { ! this_run | grep -qF -- "$1"; }
# no_call <line>: no call of this run is this whole line.
no_call() { ! this_run | grep -qxF -- "$1"; }
times() { [ "$(this_run | grep -cF -- "$2")" -eq "$1" ]; }
said() { grep -qF -- "$1" "$out"; }
not_said() { ! grep -qF -- "$1" "$out"; }
exit_is() { [ "$rc" -eq "$1" ]; }
is() { [ "$(image_of "$1")" = "$2" ]; }
same() { [ -n "$(image_of "$1")" ] && [ "$(image_of "$1")" = "$(image_of "$2")" ]; }
absent() { [ -z "$(image_of "$1")" ]; }
is_new() { case "$(image_of "$1")" in built-*) return 0 ;; *) return 1 ;; esac }
lock_is() { [ "$(cat "$state.lock")" = "$1" ]; }

images "$tag" old "$good" old "$previous" older
build SBX_STACK_CHECK=true STUB_LABEL=T0 --
expect "check passes: exit 0" exit_is 0
expect "no update: the build does not pull the base" not_called "--pull"
for name in TOOLS ZSH GIT WORKTRUNK YAZI LAZYGIT LAZYDOCKER CLAUDE NVIM; do
  expect "no update: the layer $name gets the refresh value of the good image" called "--build-arg REFRESH_$name=T0 "
done
expect "no update: the image records the refresh value of a layer" called "--label sbx-stack.refresh.nvim=T0 "
expect "no update: the build gets the plugin lock of the good image" lock_is '{"stub":"lock"}'

images "$tag" old "$good" old
build SBX_STACK_CHECK=true --
expect "no update, a good image with no refresh labels: every layer is refreshed" not_called "REFRESH_NVIM= "
expect "no update, a good image with no refresh labels: the plugin lock is empty" lock_is '{}'
expect "check passes: two template loads, the major tag and then the version tag" times 2 "sbx template load"
expect "check passes: the tag names the new image" is_new "$tag"
expect "check passes: the new image is the good one" same "$good" "$tag"
expect "check passes: the image that was good is previous" is "$previous" old
expect "check passes: prints versions.txt" called "versions.txt"

images
build SBX_STACK_CHECK=true --
expect "check passes, no good image before: exit 0" exit_is 0
expect "check passes, no good image before: warns before the build" said "cannot restore"
expect "check passes, no good image before: the new image is the good one" same "$good" "$tag"
expect "check passes, no good image before: no previous image" absent "$previous"
expect "no update, no good image: the plugin lock is empty" lock_is '{}'

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 -- --update
expect "update: exit 0" exit_is 0
expect "update: the build pulls the base" called "docker build --pull"
expect "update: no layer keeps the refresh value of the good image" not_called "=T0 "
for name in TOOLS ZSH GIT WORKTRUNK YAZI LAZYGIT LAZYDOCKER CLAUDE NVIM; do
  expect "update: the layer $name is refreshed" called "--build-arg REFRESH_$name=2"
done
expect "update: the plugin lock is empty" lock_is '{}'

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 -- --update nvim yazi
expect "update nvim yazi: exit 0" exit_is 0
expect "update nvim yazi: the build does not pull the base" not_called "--pull"
expect "update nvim yazi: nvim is refreshed" called "--build-arg REFRESH_NVIM=2"
expect "update nvim yazi: yazi is refreshed" called "--build-arg REFRESH_YAZI=2"
expect "update nvim yazi: the image records the new value" called "--label sbx-stack.refresh.yazi=2"
expect "update nvim yazi: tools keeps its value" called "--build-arg REFRESH_TOOLS=T0 "
expect "update nvim yazi: claude keeps its value" called "--build-arg REFRESH_CLAUDE=T0 "
expect "update nvim yazi: the plugin lock is empty" lock_is '{}'

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 -- --update yazi
expect "update yazi: nvim keeps its value" called "--build-arg REFRESH_NVIM=T0 "
expect "update yazi: the build gets the plugin lock of the good image" lock_is '{"stub":"lock"}'

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 STUB_KIT=2.1.314 --
expect "no update: the build keeps the Claude kit of the good image" called "--build-arg CLAUDE_KIT=2.1.314 "
expect "no update: the image records its Claude kit" called "--label sbx-stack.claude-kit=2.1.314 "
expect "no update: no lookup of the newest Claude kit" not_called "curl "

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 --
expect "no update, a good image with no kit label: the kit is latest" called "--build-arg CLAUDE_KIT=latest "

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 STUB_KIT=2.1.314 -- --update
expect "update: the build takes the newest version tag of the Claude kit" called "--build-arg CLAUDE_KIT=2.1.316 "
expect "update: the image records the new Claude kit" called "--label sbx-stack.claude-kit=2.1.316 "

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 STUB_KIT=2.1.314 -- --update nvim
expect "update nvim: the build keeps the Claude kit of the good image" called "--build-arg CLAUDE_KIT=2.1.314 "

images "$tag" old "$good" old
build SBX_STACK_CHECK=true STUB_LABEL=T0 STUB_KIT=2.1.314 STUB_TAGS=fail -- --update
expect "update, the tag lookup fails: exit 1" exit_is 1
expect "update, the tag lookup fails: says so" said "cannot find the newest Claude kit"
expect "update, the tag lookup fails: no build" not_called "docker build"

for lock_state in fail broken; do
  images "$tag" old "$good" old
  build SBX_STACK_CHECK=true STUB_LABEL=T0 "STUB_LOCK=$lock_state" --
  expect "the plugin lock read is $lock_state: exit 1" exit_is 1
  expect "the plugin lock read is $lock_state: says so" said "cannot read the plugin lock"
  expect "the plugin lock read is $lock_state: no build" not_called "docker build"
done

usage="usage: build.sh [--bump major|minor|patch|none] [--update [layer...]] | --rollback"
for bad in "--update nope" "--update ../tools" "--update ." "--rollback now" "--update nvim --rollback" \
  "--bump" "--bump big" "--bump minor --rollback" "--rollback --bump minor" "--update nvim --bump minor"; do
  # shellcheck disable=SC2086
  build -- $bad
  expect "build.sh $bad: exit 2" exit_is 2
  expect "build.sh $bad: usage" said "$usage"
  expect "build.sh $bad: no build" not_called "docker build"
done

images "$tag" old "$good" old "$previous" older
for run in first second; do
  build SBX_STACK_CHECK=false --
  expect "check fails ($run run): exit 1" exit_is 1
  expect "check fails ($run run): the tag names the good image again" is "$tag" old
  expect "check fails ($run run): the good image stays" is "$good" old
  expect "check fails ($run run): previous stays" is "$previous" older
  expect "check fails ($run run): two template loads" times 2 "sbx template load"
  expect "check fails ($run run): says restored" said "restored"
done

images
build SBX_STACK_CHECK=false --
expect "check fails, no good image: exit 1" exit_is 1
expect "check fails, no good image: one template load" times 1 "sbx template load"
expect "check fails, no good image: says so" said "no earlier image to restore"
expect "check fails, no good image: nothing is good" absent "$good"
build SBX_STACK_CHECK=true --
expect "a passed build after a failed first build: exit 0" exit_is 0
expect "a passed build after a failed first build: the failed image is not previous" absent "$previous"
expect "a passed build after a failed first build: the new image is the good one" same "$good" "$tag"

# A run that died after its build: the tag names an image that never passed the check.
images "$tag" unchecked "$good" old
build SBX_STACK_CHECK=false --
expect "check fails after a run that died: the tag names the good image, not the unchecked one" is "$tag" old
images "$tag" unchecked "$good" old
build SBX_STACK_CHECK=true --
expect "check passes after a run that died: previous is the good image, not the unchecked one" is "$previous" old

images "$tag" old "$good" old "$previous" older
build SBX_STACK_CHECK=true STUB_BUILD_FAIL=1 --
expect "the build fails: exit 1" exit_is 1
expect "the build fails: no template load" not_called "sbx template load"
expect "the build fails: no image save" not_called "docker image save"
expect "the build fails: the tag is unchanged" is "$tag" old
expect "the build fails: the good image is unchanged" is "$good" old
expect "the build fails: previous is unchanged" is "$previous" older

images "$tag" bad "$good" bad "$previous" old
build -- --rollback
expect "rollback: exit 0" exit_is 0
expect "rollback: the tag names the previous image" is "$tag" old
expect "rollback: the previous image is the good one" is "$good" old
expect "rollback: one template load" times 1 "sbx template load"
expect "rollback: no build" not_called "docker build"

images "$tag" bad "$good" bad
build -- --rollback
expect "rollback, no previous image: exit 1" exit_is 1
expect "rollback, no previous image: no template load" not_called "sbx template load"
expect "rollback, no previous image: the tag is unchanged" is "$tag" bad

build -- --force
expect "an unknown argument: exit 2" exit_is 2
expect "an unknown argument: usage" said "$usage"

# The version: --bump or a prompt gives the level; VERSION changes only after a passed check.
fresh
build SBX_STACK_CHECK=true -- --bump patch
expect "bump patch: 0.2.1" version_is 0.2.1
fresh
build SBX_STACK_CHECK=true -- --bump minor
expect "bump minor: 0.3.0" version_is 0.3.0
expect "bump minor: the build gets the new version" called "--build-arg VERSION=0.3.0 "
fresh
set_version 0.2.7
build SBX_STACK_CHECK=true -- --bump minor
expect "bump minor sets the patch level to 0" version_is 0.3.0
fresh
set_version 0.2.7
build SBX_STACK_CHECK=true -- --bump major
expect "bump major: 1.0.0" version_is 1.0.0
fresh
build SBX_STACK_CHECK=true -- --bump none
expect "bump none: the version stays" version_is 0.2.0
expect "bump none: the build gets the version of today" called "--build-arg VERSION=0.2.0 "
# docker adds a record of the build, with its times, to each image, and the image id covers the record. With the record,
# a build with no change gives a new id, and then the image to roll back to is lost.
expect "bump none: the build adds no record of the build to the image" called " --provenance=false "
fresh
build SBX_STACK_CHECK=true --
expect "no flag, no terminal: the version stays" version_is 0.2.0
expect "no flag, no terminal: says so" said "the version stays 0.2.0"
fresh
build SBX_STACK_CHECK=true STUB_LABEL=T0 -- --bump minor --update nvim
expect "bump with update: the version" version_is 0.3.0
expect "bump with update: the layer is refreshed" called "--build-arg REFRESH_NVIM=2"
expect "bump with update: another layer keeps its value" called "--build-arg REFRESH_TOOLS=T0 "
fresh
build SBX_STACK_CHECK=false -- --bump minor
expect "bump, the check fails: exit 1" exit_is 1
expect "bump, the check fails: the version stays" version_is 0.2.0
fresh
build SBX_STACK_CHECK=true STUB_BUILD_FAIL=1 -- --bump minor
expect "bump, the build fails: the version stays" version_is 0.2.0

fresh
build_on_terminal minor --
expect "terminal, the answer minor: exit 0" exit_is 0
expect "terminal, the answer minor: 0.3.0" version_is 0.3.0
expect "terminal: the prompt names the version of today" said "the version is 0.2.0"
expect "terminal: the prompt names the level and its result" said "minor  0.3.0"
fresh
build_on_terminal "" --
expect "terminal, Enter: the version stays" version_is 0.2.0
expect "terminal, Enter: the build runs" called "docker build"
fresh
build_on_terminal bogus patch --
expect "terminal, a wrong answer asks again" version_is 0.2.1
fresh
build_on_terminal minor -- --bump patch
expect "terminal with --bump: the flag counts" version_is 0.2.1
expect "terminal with --bump: no prompt" not_said "Which level"
fresh
build_on_terminal --
expect "terminal, the input ends with no answer: exit 1" exit_is 1
expect "terminal, the input ends with no answer: no build" not_called "docker build"
expect "terminal, the input ends with no answer: the version stays" version_is 0.2.0

for wrong in 0.2 v0.2.0 ""; do
  fresh
  echo "$wrong" >"$work/VERSION"
  build SBX_STACK_CHECK=true -- --bump minor
  expect "VERSION is '$wrong': exit 1" exit_is 1
  expect "VERSION is '$wrong': says so" said "VERSION must be x.y.z"
  expect "VERSION is '$wrong': no build" not_called "docker build"
done
# A file with more than one line, as a merge conflict leaves it: one line that is a version is not enough.
fresh
printf '<<<<<<< HEAD\n0.2.0\n=======\n0.3.0\n>>>>>>> other\n' >"$work/VERSION"
build SBX_STACK_CHECK=true -- --bump minor
expect "VERSION has conflict marks: exit 1" exit_is 1
expect "VERSION has conflict marks: says so" said "VERSION must be x.y.z"
expect "VERSION has conflict marks: no build" not_called "docker build"
fresh
printf '0.2.0\n0.3.0\n' >"$work/VERSION"
build SBX_STACK_CHECK=true -- --bump none
expect "VERSION has two versions: exit 1" exit_is 1
expect "VERSION has two versions: no build" not_called "docker build"
set_version "$version"

# The two tags: the build, the load and the check use the major tag. The version tag comes after a passed check.
next=sbx-stack-base:0.3.0
fresh
build SBX_STACK_CHECK=true -- --bump minor
expect "bump, the check passes: the major tag names the new image" is_new "$tag"
expect "bump, the check passes: the version tag names the same image" same "$next" "$tag"
expect "bump, the check passes: the old version tag is gone from docker" absent "$vtag"
expect "bump, the check passes: the old version tag is gone from sbx" called "sbx template rm --force $vtag"
expect "bump, the check passes: two template loads" times 2 "sbx template load"
expect "bump, the check passes: the first load is the major tag" called "docker image save $tag -o"
expect "bump, the check passes: the second load is the version tag" called "docker image save $next -o"
expect "bump, the check passes: the new image is the good one" same "$good" "$tag"
fresh
build SBX_STACK_CHECK=true -- --bump none
expect "no bump: the version tag is loaded again" called "docker image save $vtag -o"
expect "no bump: the version tag names the new image" same "$vtag" "$tag"
expect "no bump: the major tag names the new image" is_new "$tag"
expect "no bump: no template is removed" not_called "sbx template rm"
fresh
build "SBX_STACK_CHECK=$bin/check-env" "CHECK_VERSION_FILE=$tmp/check-version" -- --bump minor
expect "the check gets the new version" [ "$(cat "$tmp/check-version")" = 0.3.0 ]
fresh
build SBX_STACK_CHECK=false -- --bump minor
expect "bump, the check fails: no new version tag" absent "$next"
expect "bump, the check fails: the old version tag stays" is "$vtag" old
expect "bump, the check fails: the major tag names the good image again" is "$tag" old
expect "bump, the check fails: no template is removed" not_called "sbx template rm"
fresh
build SBX_STACK_CHECK=false -- --bump major
expect "a failed major bump: exit 1" exit_is 1
expect "a failed major bump: the new major tag is gone from docker" absent sbx-stack-base:1
expect "a failed major bump: the new major tag is gone from sbx" called "sbx template rm --force sbx-stack-base:1"
expect "a failed major bump: the old major tag is unchanged" is "$tag" old
expect "a failed major bump: one template load" times 1 "sbx template load"
expect "a failed major bump: the version stays" version_is 0.2.0
fresh
build SBX_STACK_CHECK=true -- --bump major
expect "a passed major bump: the old major tag stays" is "$tag" old
expect "a passed major bump: the new major tag names the new image" is_new sbx-stack-base:1
expect "a passed major bump: the new version tag names the same image" same sbx-stack-base:1.0.0 sbx-stack-base:1
expect "a passed major bump: the old version tag is gone" absent "$vtag"

# One version tag at a time: a passed build removes each other version tag that docker or sbx holds, also one that
# VERSION does not name (a build that stopped, a VERSION that changed by hand).
fresh
images "$tag" old "$vtag" old sbx-stack-base:0.1.9 older "$good" old "$previous" older
echo '[{"repository":"docker.io/library/sbx-stack-base","tag":"0"},
{"repository":"docker.io/library/sbx-stack-base","tag":"0.1.8"},
{"repository":"docker.io/library/other-base","tag":"0.1.7"}]' >"$tmp/templates"
build SBX_STACK_CHECK=true "STUB_TEMPLATES=$tmp/templates" -- --bump minor
expect "a stale version tag in docker is gone" absent sbx-stack-base:0.1.9
expect "a stale version tag in docker is gone from sbx" called "sbx template rm --force sbx-stack-base:0.1.9"
expect "a stale version tag that only sbx holds is gone" called "sbx template rm --force sbx-stack-base:0.1.8"
expect "the new version tag stays" same "$next" "$tag"
expect "the major tag is not removed" no_call "sbx template rm --force $tag"
expect "the good tag is not removed" no_call "sbx template rm --force $good"
expect "a template of another image is not removed" not_called "0.1.7"

# A build that stops after the passed check: the version tag does not reach sbx.
fresh
images "$tag" old "$vtag" old "$good" old "$previous" older
build SBX_STACK_CHECK=true "STUB_SAVE_FAIL=$next" -- --bump minor
expect "the load of the version tag fails: exit 1" exit_is 1
expect "the load of the version tag fails: says that the check passed" said "the check passed, but"
expect "the load of the version tag fails: names the command to run" said "Run the same command again"
expect "the load of the version tag fails: VERSION stays" version_is 0.2.0
expect "the load of the version tag fails: the new image is the good one" same "$good" "$tag"
expect "the load of the version tag fails: the image that was good is previous" is "$previous" old
build SBX_STACK_CHECK=true -- --bump minor
expect "the same command again: exit 0" exit_is 0
expect "the same command again: the version" version_is 0.3.0
expect "the same command again: the old version tag is gone" absent "$vtag"
expect "the same command again: the old version tag is gone from sbx" called "sbx template rm --force $vtag"
fresh
build SBX_STACK_CHECK=true STUB_TEMPLATES=fail -- --bump minor
expect "the template list fails after the check: exit 1" exit_is 1
expect "the template list fails after the check: says that the check passed" said "the check passed, but"
expect "the template list fails after the check: VERSION stays" version_is 0.2.0
fresh
build SBX_STACK_CHECK=false -- --bump minor
expect "the check fails: no line about a passed check" not_said "the check passed"

# A build that gives the good image again (no change, or the same command after a stop) keeps the previous image.
fresh
images "$tag" old "$vtag" old "$good" old "$previous" older
build SBX_STACK_CHECK=true STUB_BUILD_ID=old -- --bump none
expect "the build gives the good image again: exit 0" exit_is 0
expect "the build gives the good image again: previous stays" is "$previous" older
expect "the build gives the good image again: good stays" is "$good" old

# The rollback: the previous image comes back under its two tags, and VERSION gets its version.
set_version 0.3.0
images "$tag" bad "$next" bad "$good" bad "$previous" old
build STUB_VERSION=0.2.0 -- --rollback
expect "rollback after a bump: exit 0" exit_is 0
expect "rollback after a bump: VERSION is the version of the previous image" version_is 0.2.0
expect "rollback after a bump: the major tag names the previous image" is "$tag" old
expect "rollback after a bump: its version tag names it too" is "$vtag" old
expect "rollback after a bump: the newer version tag is gone from docker" absent "$next"
expect "rollback after a bump: the newer version tag is gone from sbx" called "sbx template rm --force $next"
expect "rollback after a bump: one template load" times 1 "sbx template load"
expect "rollback after a bump: the load has both tags" called "docker image save $tag $vtag "
expect "rollback after a bump: the previous image is the good one" is "$good" old
set_version 0.2.0
images "$tag" bad "$vtag" bad "$good" bad "$previous" old
build STUB_VERSION=0.2.0 -- --rollback
expect "rollback with the same version: the version tag names the previous image" is "$vtag" old
expect "rollback with the same version: no template is removed" not_called "sbx template rm"
set_version 1.0.0
images "$tag" old sbx-stack-base:1 bad sbx-stack-base:1.0.0 bad "$good" bad "$previous" old
build STUB_VERSION=0.2.0 -- --rollback
expect "rollback over a major bump: VERSION" version_is 0.2.0
expect "rollback over a major bump: the newer major tag is gone" absent sbx-stack-base:1
expect "rollback over a major bump: the newer version tag is gone" absent sbx-stack-base:1.0.0
expect "rollback over a major bump: says which tag the files must name" said "must name $tag again"
# A build stopped after its check and before it wrote VERSION: docker has a version tag that VERSION does not name.
set_version 0.2.0
images "$tag" bad "$next" bad "$vtag" stale "$good" bad "$previous" old
build STUB_VERSION=0.2.0 -- --rollback
expect "rollback after a stopped build: the version tag that VERSION does not name is gone" absent "$next"
expect "rollback after a stopped build: the version tag names the previous image" is "$vtag" old
set_version 0.3.0
images "$tag" bad "$next" bad "$good" bad "$previous" old
build STUB_VERSION=fail -- --rollback
expect "rollback, the version of the previous image cannot be read: exit 1" exit_is 1
expect "rollback, the version cannot be read: says so" said "cannot read the version of $previous"
expect "rollback, the version cannot be read: no template load" not_called "sbx template load"
expect "rollback, the version cannot be read: VERSION is unchanged" version_is 0.3.0
expect "rollback, the version cannot be read: the tag is unchanged" is "$tag" bad
set_version "$version"

# The record of the commit: the image gets the commit, with a mark when the folder has changes that are not committed.
fresh
git -C "$work" add -A
git -C "$work" -c user.name=test -c user.email=test@example.com commit -q -m "all files"
head=$(git -C "$work" rev-parse HEAD)
build SBX_STACK_CHECK=true -- --bump none
expect "all is committed: the image records the commit" called "--build-arg REVISION=$head "
expect "all is committed: the label has the commit" called "--label org.opencontainers.image.revision=$head "
echo change >"$work/not-committed"
build SBX_STACK_CHECK=true -- --bump none
expect "a change is not committed: the image records the commit with a mark" called "--build-arg REVISION=$head+changes "
expect "a change is not committed: the label has the mark" called "--label org.opencontainers.image.revision=$head+changes "
rm "$work/not-committed"

# The copy of the good image: one tar file outside docker. It holds the good image of this moment, or it is absent.
images "$tag" old "$good" old
build SBX_STACK_CHECK=true --
expect "a passed build: the good image is a new one" is_new "$good"
expect "a passed build: the copy holds the new good image" copy_holds "$(image_of "$good")"
expect "a passed build: the save goes to a temporary name" called "docker image save $good -o $copy.new"
expect "a passed build: no part of a file stays" [ ! -e "$copy.new" ]
images
build SBX_STACK_CHECK=true --
expect "a first build: the copy holds the good image" copy_holds "$(image_of "$good")"

images "$tag" old "$good" old
a_copy old
build SBX_STACK_CHECK=false --
expect "the check fails: the copy is unchanged" copy_holds old
images "$tag" old "$good" old
a_copy old
build SBX_STACK_CHECK=true STUB_BUILD_FAIL=1 --
expect "the build fails: the copy is unchanged" copy_holds old

images "$tag" bad "$good" bad "$previous" old
a_copy bad
build -- --rollback
expect "rollback: the copy holds the image that is good now" copy_holds old

# After a prune of docker: no good image, and a copy.
images "$tag" old
a_copy kept
build SBX_STACK_CHECK=true STUB_LABEL=T0 STUB_KIT=2.1.314 --
expect "no good image, a copy: exit 0" exit_is 0
expect "no good image, a copy: the build loads the copy" called "docker image load -i $copy"
expect "no good image, a copy: says so" said "restored $good from"
expect "no good image, a copy: no warning" not_said "cannot restore"
expect "no good image, a copy: the build keeps the Claude kit of the good image" called "--build-arg CLAUDE_KIT=2.1.314 "
expect "no good image, a copy: no lookup of the newest Claude kit" not_called "curl "
expect "no good image, a copy: a layer keeps its refresh value" called "--build-arg REFRESH_NVIM=T0 "
expect "no good image, a copy: the build gets the plugin lock of the good image" lock_is '{"stub":"lock"}'
expect "no good image, a copy: the restored image is previous after the pass" is "$previous" kept
expect "no good image, a copy: the good image is a new one" is_new "$good"
expect "no good image, a copy: the copy holds the new good image" copy_holds "$(image_of "$good")"
images "$tag" old
a_copy kept
build SBX_STACK_CHECK=false --
expect "no good image, a copy, the check fails: the tag names the restored image" is "$tag" kept
expect "no good image, a copy, the check fails: the copy is unchanged" copy_holds kept

images "$tag" old
a_copy kept
build SBX_STACK_CHECK=true STUB_LOAD_FAIL=1 --
expect "the copy does not load: exit 1" exit_is 1
expect "the copy does not load: says so" said "cannot load"
expect "the copy does not load: no build" not_called "docker build"
expect "the copy does not load: the file stays for the owner" copy_holds kept
images "$tag" old
a_copy ""
build SBX_STACK_CHECK=true --
expect "the copy gives no good tag: exit 1" exit_is 1
expect "the copy gives no good tag: says so" said "cannot load"
expect "the copy gives no good tag: no build" not_called "docker build"
# docker is down: the copy is not the cause, and the owner must not remove it.
images "$tag" old
a_copy kept
build SBX_STACK_CHECK=true STUB_DOCKER_DOWN=1 --
expect "docker does not answer: exit 1" exit_is 1
expect "docker does not answer: says so" said "docker does not answer"
expect "docker does not answer: does not blame the copy" not_said "cannot load"
expect "docker does not answer: no load" not_called "docker image load"
expect "docker does not answer: the copy stays" copy_holds kept

images "$tag" old
build SBX_STACK_CHECK=true --
expect "no good image, no copy: the warning of a first build" said "cannot restore"
expect "no good image, no copy: no load" not_called "docker image load"
images "$tag" old "$good" old
a_copy old
build SBX_STACK_CHECK=true --
expect "a good image in docker: the copy is not loaded" not_called "docker image load"

images "$tag" old "$good" old
a_copy old
build SBX_STACK_CHECK=true "STUB_SAVE_FAIL=$good" --
expect "the save of the copy fails: exit 0" exit_is 0
expect "the save of the copy fails: no copy and no part of a file" no_copy
expect "the save of the copy fails: says so" said "no copy"
expect "the save of the copy fails: the good image is a new one" is_new "$good"
expect "the save of the copy fails: the tag names the good image" same "$good" "$tag"

# A copy that is older than the good image would give older tools with no message.
fresh
a_copy old
build SBX_STACK_CHECK=true "STUB_SAVE_FAIL=$next" -- --bump minor
expect "a run that stops after the good tag moved: exit 1" exit_is 1
expect "a run that stops after the good tag moved: the good image is a new one" is_new "$good"
expect "a run that stops after the good tag moved: the copy holds the new good image" copy_holds "$(image_of "$good")"
set_version "$version"
# The old copy goes before the good tag moves: a run that dies during the save leaves no copy, never the old one.
# The shell of this test reports the kill on stderr, so stderr goes nowhere for this run.
images "$tag" old "$good" old
a_copy old
build SBX_STACK_CHECK=true "STUB_SAVE_KILL=$good" -- 2>/dev/null
expect "a run that dies during the save: it died" [ "$rc" -gt 128 ]
expect "a run that dies during the save: the good image is a new one" is_new "$good"
expect "a run that dies during the save: the old copy is gone" [ ! -e "$copy" ]
build SBX_STACK_CHECK=true --
expect "the next passed build: no part of a file stays" [ ! -e "$copy.new" ]
expect "the next passed build: the copy holds the good image" copy_holds "$(image_of "$good")"

# A stop by a signal during the save (Ctrl-C): the cleanup of build.sh removes the part of a file.
images "$tag" old "$good" old
a_copy old
build SBX_STACK_CHECK=true "STUB_SAVE_KILL=$good" STUB_KILL_SIGNAL=TERM -- 2>/dev/null
expect "a run that gets TERM during the save: it stopped" [ "$rc" -ne 0 ]
expect "a run that gets TERM during the save: no part of a file stays" [ ! -e "$copy.new" ]
expect "a run that gets TERM during the save: the old copy is gone" [ ! -e "$copy" ]
# A part of a file that a killed run left goes at the start of the next run, also when that run does not pass.
images "$tag" old "$good" old
a_copy old
echo partial >"$copy.new"
build SBX_STACK_CHECK=false --
expect "a part of a file from a killed run: the next run removes it" [ ! -e "$copy.new" ]
expect "a part of a file from a killed run: the copy is unchanged" copy_holds old

# A copy path that build.sh cannot read is not "no copy": with no good image, the build would take the newest
# version of everything.
images "$tag" old
mkdir -p "$(dirname "$copy")"
ln -s "$tmp/nowhere" "$copy"
build SBX_STACK_CHECK=true --
expect "the copy is a link to nothing: exit 1" exit_is 1
expect "the copy is a link to nothing: says so" said "cannot read the copy"
expect "the copy is a link to nothing: no build" not_called "docker build"
images "$tag" old
mkdir -p "$copy"
build SBX_STACK_CHECK=true --
rmdir "$copy"
expect "the copy path is a folder: exit 1" exit_is 1
expect "the copy path is a folder: says so" said "cannot read the copy"
expect "the copy path is a folder: no build" not_called "docker build"
# The user root reads each file and searches each folder, so these two cases need another user.
if [ "$(id -u)" -ne 0 ]; then
  images "$tag" old
  a_copy kept
  chmod 000 "$(dirname "$copy")"
  build SBX_STACK_CHECK=true --
  chmod 700 "$(dirname "$copy")"
  expect "the folder of the copy cannot be searched: exit 1" exit_is 1
  expect "the folder of the copy cannot be searched: says so" said "cannot read the copy"
  expect "the folder of the copy cannot be searched: no build" not_called "docker build"
  expect "the folder of the copy cannot be searched: the copy stays" copy_holds kept
  images "$tag" old
  a_copy kept
  chmod 000 "$copy"
  build SBX_STACK_CHECK=true --
  chmod 600 "$copy"
  expect "the copy cannot be read: exit 1" exit_is 1
  expect "the copy cannot be read: says so" said "cannot read the copy"
  expect "the copy cannot be read: no build" not_called "docker build"
fi

# A rollback needs the previous image. It does not read the copy.
images "$tag" bad
a_copy kept
build -- --rollback
expect "rollback, no good and no previous image, a copy: exit 1" exit_is 1
expect "rollback, no good and no previous image, a copy: the copy is not loaded" not_called "docker image load"
expect "rollback, no good and no previous image, a copy: the copy is unchanged" copy_holds kept

# The path of the copy has one source: XDG_STATE_HOME, or HOME. A variable of its own would leave a copy at the
# other path, older than the good image. HOME is below the temporary folder here.
images "$tag" old "$good" old
build SBX_STACK_CHECK=true "HOME=$tmp/home" XDG_STATE_HOME= --
expect "no XDG_STATE_HOME: the copy is below HOME" [ -f "$tmp/home/.local/state/sbx-stack-base/good.tar" ]
images "$tag" old "$good" old
build SBX_STACK_CHECK=true "SBX_STACK_GOOD_COPY=$tmp/other.tar" --
expect "no variable names another path: no file at that path" [ ! -e "$tmp/other.tar" ]
expect "no variable names another path: the copy is at its one path" copy_holds "$(image_of "$good")"

# The instances. With the tool sbx-instance in PATH, each sbx instance on its list is a target of the template. The
# build, the first load and the check use plain sbx: the instance of the folder. Each other instance gets the image
# after the check passed.
# The stub of the tool: STUB_INSTANCES is its list ("fail" makes the list fail), "which" prints check, and
# "run <name> -- ..." answers as sbx in that instance: STUB_STOPPED holds the instances whose daemon does not run,
# STUB_LOAD_FAIL_IN the instances where a template load fails.
ibin=$tmp/ibin
mkdir -p "$ibin"
cat >"$ibin/sbx-instance" <<'EOF'
#!/usr/bin/env bash
echo "sbx-instance $*" >>"$STUB_LOG"
case "$1" in
  list)
    [ "${STUB_INSTANCES:-}" != fail ] || exit 1
    # shellcheck disable=SC2086
    printf '%s\n' $STUB_INSTANCES
    ;;
  which)
    if [ -n "${STUB_WHICH_FAILS:-}" ]; then
      echo "sbx-instances: no instance for the folder" >&2
      exit 64
    fi
    echo check
    ;;
  run)
    name=$2
    shift 3
    [ "$1" != --no-input ] || shift
    case "$1 ${2:-}" in
      "daemon status")
        case " ${STUB_STOPPED:-} " in
          *" $name "*) echo "  Status:  stopped" ;;
          *) echo "  Status:  ● running" ;;
        esac
        # STUB_STATUS_MORE=1: the answer has a second Status line, for a part of the daemon that does not run.
        [ -z "${STUB_STATUS_MORE:-}" ] || echo "  Status:  stopped (kit registry)"
        ;;
      "ls "*)
        # STUB_SIGNED_OUT_IN holds the instances that are not signed in to Docker: sbx ls fails there.
        case " ${STUB_SIGNED_OUT_IN:-} " in
          *" $name "*) exit 1 ;;
        esac
        # "ls --json": one sandbox. STUB_RUNNING_IN holds the instances where it runs; elsewhere it is stopped.
        if [ "${2:-}" = --json ]; then
          case " ${STUB_RUNNING_IN:-} " in
            *" $name "*) echo '[{"name":"box","status":"running"}]' ;;
            *) echo '[{"name":"box","status":"stopped"}]' ;;
          esac
        fi
        ;;
      "template load")
        # STUB_SIGNAL_IN is an instance: build.sh gets the signal TERM during the load into it.
        if [ "${STUB_SIGNAL_IN:-}" = "$name" ]; then
          kill -TERM "$PPID"
          sleep 1
          exit 1
        fi
        case " ${STUB_LOAD_FAIL_IN:-} " in
          *" $name "*)
            echo "error: daemon fault" >&2
            exit 1
            ;;
        esac
        ;;
      "template ls")
        if [ -n "${STUB_TEMPLATES:-}" ]; then cat "$STUB_TEMPLATES"; else echo '[]'; fi
        ;;
    esac
    ;;
esac
EOF
chmod +x "$ibin/sbx-instance"
# ibuild <VAR=value>... -- <build.sh arguments>: as build, with the tool in PATH and three instances on its list.
ibuild() { build "PATH=$ibin:$bin:$clean" "STUB_INSTANCES=check alpha beta" "$@"; }
# call_is <line>: a call of this run is this whole line.
call_is() { this_run | grep -qxF -- "$1"; }
# in_order <text> <text>: the last call with the first text comes before the first call with the second text.
in_order() {
  local first second
  first=$(this_run | grep -nF -- "$1" | tail -1 | cut -d: -f1)
  second=$(this_run | grep -nF -- "$2" | head -1 | cut -d: -f1)
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

fresh
build SBX_STACK_CHECK=true --
expect "no sbx-instance: exit 0" exit_is 0
expect "no sbx-instance: no call of the tool" not_called "sbx-instance"
expect "no sbx-instance: the two template loads of today" times 2 "sbx template load"

fresh
echo '[{"repository":"docker.io/library/sbx-stack-base","tag":"0"},
{"repository":"docker.io/library/sbx-stack-base","tag":"0.1.8"},
{"repository":"docker.io/library/sbx-stack-base","tag":"0.3.0"},
{"repository":"docker.io/library/other-base","tag":"0.1.7"}]' >"$tmp/templates"
ibuild SBX_STACK_CHECK=true "STUB_TEMPLATES=$tmp/templates" -- --bump minor
expect "three instances: exit 0" exit_is 0
expect "three instances: the check instance gets its two loads with plain sbx" times 2 "sbx template load"
expect "three instances: the image goes into alpha" called "sbx-instance run alpha -- --no-input template load "
expect "three instances: the image goes into beta" called "sbx-instance run beta -- --no-input template load "
expect "three instances: no second load into the check instance" not_called "sbx-instance run check"
expect "three instances: the other instances get the image after the loads of the check instance" \
  in_order "sbx template load" "sbx-instance run"
expect "three instances: the load into the other instances has both tags" called "docker image save $tag $next -o"
expect "three instances: a stale version tag is gone from alpha" \
  call_is "sbx-instance run alpha -- --no-input template rm --force sbx-stack-base:0.1.8"
expect "three instances: a stale version tag is gone from beta" \
  call_is "sbx-instance run beta -- --no-input template rm --force sbx-stack-base:0.1.8"
expect "three instances: the new version tag stays in alpha" \
  no_call "sbx-instance run alpha -- --no-input template rm --force $next"
expect "three instances: the major tag stays in alpha" no_call "sbx-instance run alpha -- --no-input template rm --force $tag"
expect "three instances: a template of another name stays in alpha" not_called "other-base"
expect "three instances: the output names the instances" said "the instance alpha"
expect "three instances: the version is the new one" version_is 0.3.0

fresh
ibuild SBX_STACK_CHECK=true STUB_INSTANCES=check --
expect "only the check instance on the list: exit 0" exit_is 0
expect "only the check instance on the list: no load into another instance" not_called "sbx-instance run"
expect "only the check instance on the list: no extra save" times 2 "docker image save $tag"

fresh
ibuild SBX_STACK_CHECK=false --
expect "three instances, the check fails: exit 1" exit_is 1
expect "three instances, the check fails: no other instance gets the image" not_called "sbx-instance run"
expect "three instances, the check fails: the check instance has the good image again" said "restored"
expect "three instances, the check fails: the tag names the good image" is "$tag" old

# A failed load into one instance must not pass without a word, and must not stop the loads into the others.
fresh
ibuild SBX_STACK_CHECK=true STUB_LOAD_FAIL_IN=alpha -- --bump minor
expect "a failed load into alpha: exit 1" exit_is 1
expect "a failed load into alpha: the output names the instance" said "the instance alpha"
expect "a failed load into alpha: the output names the repair" said "build.sh --load"
expect "a failed load into alpha: beta still gets the image" called "sbx-instance run beta -- --no-input template load "
expect "a failed load into alpha: no version tag is removed in alpha" not_called "sbx-instance run alpha -- --no-input template ls"
expect "a failed load into alpha: the version is the new one" version_is 0.3.0
expect "a failed load into alpha: the new image is the good one" is_new "$good"
expect "a failed load into alpha: no line about a stop before the end" not_said "stopped before its end"

fresh
ibuild SBX_STACK_CHECK=true STUB_STOPPED=alpha --
expect "a daemon that was stopped: exit 0" exit_is 0
expect "a daemon that was stopped is stopped again" call_is "sbx-instance run alpha -- --no-input daemon stop"
expect "a daemon that was stopped: the stop comes after the load" \
  in_order "sbx-instance run alpha -- --no-input template load" "sbx-instance run alpha -- --no-input daemon stop"
expect "a daemon that ran is not stopped" not_called "sbx-instance run beta -- --no-input daemon stop"
fresh
ibuild SBX_STACK_CHECK=true STUB_STOPPED=alpha STUB_LOAD_FAIL_IN=alpha --
expect "a daemon that was stopped, and the load fails: it is stopped again" \
  call_is "sbx-instance run alpha -- --no-input daemon stop"

# A load takes about a minute: a person can start a sandbox in the instance in that time.
fresh
ibuild SBX_STACK_CHECK=true STUB_STOPPED=alpha --
expect "a daemon that was stopped: the build looks at the sandboxes just before the stop" \
  in_order "sbx-instance run alpha -- --no-input ls --json" "sbx-instance run alpha -- --no-input daemon stop"
fresh
ibuild SBX_STACK_CHECK=true STUB_STOPPED=alpha STUB_RUNNING_IN=alpha --
expect "a sandbox that runs now: exit 0" exit_is 0
expect "a sandbox that runs now: the daemon is not stopped" not_called "sbx-instance run alpha -- --no-input daemon stop"
expect "a sandbox that runs now: a line says why the daemon runs on" said "the daemon of the instance alpha stays running"

# A name with a typing error in the list is an instance that nobody signed in: it gets no 4.2 GB image.
fresh
ibuild SBX_STACK_CHECK=true STUB_SIGNED_OUT_IN=alpha -- --bump minor
expect "an instance that is not signed in: exit 1" exit_is 1
expect "an instance that is not signed in: no load into it" \
  not_called "sbx-instance run alpha -- --no-input template load"
expect "an instance that is not signed in: the output names it and a typing error" said "a typing error"
expect "an instance that is not signed in: the output names the sign-in" said "sbx-instance run alpha -- login"
expect "an instance that is not signed in: beta still gets the image" \
  called "sbx-instance run beta -- --no-input template load "

fresh
ibuild SBX_STACK_CHECK=true STUB_STATUS_MORE=1 --
expect "a running daemon with a second Status line is not stopped" not_called "daemon stop"
fresh
ibuild SBX_STACK_CHECK=true STUB_STOPPED=alpha STUB_STATUS_MORE=1 --
expect "a stopped daemon with a second Status line is stopped again" \
  call_is "sbx-instance run alpha -- --no-input daemon stop"

# A signal during the loads into the other instances: VERSION holds the new version already, so the same command
# again would raise the version a second time. The output names the command that does the loads again.
fresh
ibuild SBX_STACK_CHECK=true STUB_SIGNAL_IN=alpha STUB_STOPPED=alpha -- --bump minor
expect "a signal during the load into alpha: the status is not 0" [ "$rc" -ne 0 ]
expect "a signal during the load into alpha: VERSION holds the new version" version_is 0.3.0
expect "a signal during the load into alpha: no line that VERSION is the old one" not_said "VERSION is still"
expect "a signal during the load into alpha: no advice to run the same command again" \
  not_said "Run the same command again"
expect "a signal during the load into alpha: the output names the version" said "VERSION holds 0.3.0"
expect "a signal during the load into alpha: the output names the repair" said "build.sh --load"
expect "a signal during the load into alpha: its daemon, which was stopped, is stopped again" \
  call_is "sbx-instance run alpha -- --no-input daemon stop"
set_version 0.3.0
images "$tag" bad "$next" bad "$good" bad "$previous" old
ibuild STUB_VERSION=0.2.0 STUB_SIGNAL_IN=alpha -- --rollback
expect "rollback, a signal during the load into alpha: the output names the repair" said "build.sh --load"
fresh
images "$tag" old "$vtag" old "$good" old
ibuild STUB_VERSION=0.2.0 STUB_SIGNAL_IN=beta -- --load
expect "--load, a signal during the load into beta: the output names the repair" said "build.sh --load"

# --load: the good image goes into each target again. No build, no check.
fresh
images "$tag" bad "$vtag" old "$good" old "$previous" older
ibuild SBX_STACK_CHECK=false STUB_VERSION=0.2.0 -- --load
expect "--load: exit 0" exit_is 0
expect "--load: no build" not_called "docker build"
expect "--load: the major tag names the good image" is "$tag" old
expect "--load: one load into the check instance, with both tags" times 1 "sbx template load"
expect "--load: the save has both tags" called "docker image save $tag $vtag -o"
expect "--load: the image goes into alpha" called "sbx-instance run alpha -- --no-input template load "
expect "--load: the image goes into beta" called "sbx-instance run beta -- --no-input template load "
expect "--load: VERSION is unchanged" version_is 0.2.0
expect "--load: the good image is unchanged" is "$good" old
expect "--load: previous is unchanged" is "$previous" older
fresh
build STUB_VERSION=0.2.0 -- --load
expect "--load with no sbx-instance: exit 0" exit_is 0
expect "--load with no sbx-instance: one load with plain sbx" times 1 "sbx template load"
fresh
ibuild STUB_VERSION=0.2.0 STUB_LOAD_FAIL_IN=beta -- --load
expect "--load, a failed load into beta: exit 1" exit_is 1
expect "--load, a failed load into beta: the output names the instance" said "the instance beta"
expect "--load, a failed load into beta: alpha gets the image" called "sbx-instance run alpha -- --no-input template load "
images
a_copy kept
ibuild STUB_VERSION=0.2.0 -- --load
expect "--load, no good image, a copy: the copy is loaded first" called "docker image load -i $copy"
expect "--load, no good image, a copy: the major tag names the restored image" is "$tag" kept
expect "--load, no good image, a copy: the image goes into alpha" called "sbx-instance run alpha -- --no-input template load "
images
ibuild -- --load
expect "--load, no good image, no copy: exit 1" exit_is 1
expect "--load, no good image, no copy: says so" said "no $good image"
expect "--load, no good image, no copy: no load" not_called "template load"
fresh
ibuild -- --load --update
expect "--load with --update: the usage" exit_is 2
ibuild -- --bump minor --load
expect "--load with --bump: the usage" exit_is 2
ibuild -- --load --rollback
expect "--load with --rollback: the usage" exit_is 2
expect "--load with another option: nothing ran" not_called "template load"

# The rollback goes into each target.
set_version 0.3.0
images "$tag" bad "$next" bad "$good" bad "$previous" old
ibuild STUB_VERSION=0.2.0 -- --rollback
expect "rollback, three instances: exit 0" exit_is 0
expect "rollback, three instances: the previous image goes into alpha" called "sbx-instance run alpha -- --no-input template load "
expect "rollback, three instances: the previous image goes into beta" called "sbx-instance run beta -- --no-input template load "
expect "rollback, three instances: VERSION is the version of the previous image" version_is 0.2.0
set_version 1.0.0
images sbx-stack-base:1 bad sbx-stack-base:1.0.0 bad "$good" bad "$previous" old
ibuild STUB_VERSION=0.2.0 -- --rollback
expect "rollback over a major bump: the newer major tag is gone from alpha" \
  call_is "sbx-instance run alpha -- --no-input template rm --force sbx-stack-base:1"
expect "rollback over a major bump: the newer major tag is gone from beta" \
  call_is "sbx-instance run beta -- --no-input template rm --force sbx-stack-base:1"
set_version 0.3.0
images "$tag" bad "$next" bad "$good" bad "$previous" old
ibuild STUB_VERSION=0.2.0 STUB_LOAD_FAIL_IN=alpha -- --rollback
expect "rollback, a failed load into alpha: exit 1" exit_is 1
expect "rollback, a failed load into alpha: the output names the repair" said "build.sh --load"
expect "rollback, a failed load into alpha: the previous image is the good one" is "$good" old

# A tool that cannot name the instances stops the build before it starts.
fresh
ibuild SBX_STACK_CHECK=true STUB_INSTANCES=fail --
expect "sbx-instance list fails: exit 1" exit_is 1
expect "sbx-instance list fails: says so" said "sbx-instance list"
expect "sbx-instance list fails: no build" not_called "docker build"
ibuild SBX_STACK_CHECK=true STUB_WHICH_FAILS=1 --
expect "the folder has no instance: exit 1" exit_is 1
expect "the folder has no instance: says so" said "sbx-instance which"
expect "the folder has no instance: no build" not_called "docker build"
expect "the folder has no instance: no template load" not_called "template load"

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
passed=1
