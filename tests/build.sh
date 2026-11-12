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
chmod +x "$bin/docker" "$bin/sbx" "$bin/curl"

cp "$repo/build.sh" "$repo/VERSION" "$work/"
for layer in tools zsh git worktrunk yazi claude nvim; do
  mkdir -p "$work/layers/$layer"
  : >"$work/layers/$layer/install.sh"
done
git -C "$work" init -q
git -C "$work" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m test
version=$(cat "$repo/VERSION")
tag=sbx-stack-base:$version
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
  env "${envs[@]}" "$BASH" "$work/build.sh" "$@" >"$out" 2>&1 || rc=$?
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
for name in TOOLS ZSH GIT WORKTRUNK YAZI CLAUDE NVIM; do
  expect "no update: the layer $name gets the refresh value of the good image" called "--build-arg REFRESH_$name=T0 "
done
expect "no update: the image records the refresh value of a layer" called "--label sbx-stack.refresh.nvim=T0 "
expect "no update: the build gets the plugin lock of the good image" lock_is '{"stub":"lock"}'

images "$tag" old "$good" old
build SBX_STACK_CHECK=true --
expect "no update, a good image with no refresh labels: every layer is refreshed" not_called "REFRESH_NVIM= "
expect "no update, a good image with no refresh labels: the plugin lock is empty" lock_is '{}'
expect "check passes: one template load" times 1 "sbx template load"
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
for name in TOOLS ZSH GIT WORKTRUNK YAZI CLAUDE NVIM; do
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

for bad in "--update nope" "--update ../tools" "--update ." "--rollback now" "--update nvim --rollback"; do
  # shellcheck disable=SC2086
  build -- $bad
  expect "build.sh $bad: exit 2" exit_is 2
  expect "build.sh $bad: usage" said "usage: build.sh [--update [layer...] | --rollback]"
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
expect "an unknown argument: usage" said "usage: build.sh [--update [layer...] | --rollback]"

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
passed=1
