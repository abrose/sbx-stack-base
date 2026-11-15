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
      *) echo 1000000 ;;
    esac
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
    echo "$2 built-$(wc -l <"$STUB_LOG" | tr -d ' ')" >>"$STUB_STATE"
    ;;
esac
EOF
cat >"$bin/sbx" <<'EOF'
#!/usr/bin/env bash
echo "sbx $*" >>"$STUB_LOG"
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

# images <ref id>...: the images that exist before the next run.
images() {
  : >"$state"
  : >"$state.lock"
  while [ $# -gt 0 ]; do
    echo "$1 $2" >>"$state"
    shift 2
  done
}

image_of() { awk -v ref="$1" '$1 == ref {print $2}' "$state"; }

# build <VAR=value>... -- <build.sh arguments>: runs build.sh with the stubs; sets rc, $calls and $out.
# stdin is not a terminal, so build.sh asks nothing, also when a person runs these tests in a terminal.
build() {
  local envs=("PATH=$bin:$PATH" "STUB_LOG=$calls" "STUB_STATE=$state")
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
    env "PATH=$bin:$PATH" "STUB_LOG=$calls" "STUB_STATE=$state" SBX_STACK_CHECK=true \
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
expect "bump, the check passes: the new image is the good one" same "$good" "$tag"
fresh
build SBX_STACK_CHECK=true -- --bump none
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

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
passed=1
