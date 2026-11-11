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
    echo 1000000
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
  build\ *)
    [ "${STUB_BUILD_FAIL:-0}" -eq 0 ] || exit 1
    while [ "$1" != -t ]; do shift; done
    untag "$2"
    echo "$2 built-$(wc -l <"$STUB_LOG" | tr -d ' ')" >>"$STUB_STATE"
    ;;
esac
EOF
cat >"$bin/sbx" <<'EOF'
#!/usr/bin/env bash
echo "sbx $*" >>"$STUB_LOG"
EOF
chmod +x "$bin/docker" "$bin/sbx"

cp "$repo/build.sh" "$repo/VERSION" "$work/"
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

images "$tag" old "$good" old "$previous" older
build SBX_STACK_CHECK=true --
expect "check passes: exit 0" exit_is 0
expect "check passes: the build pulls the base" called "docker build --pull"
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
expect "an unknown argument: usage" said "usage: build.sh [--rollback]"

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
passed=1
