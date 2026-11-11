#!/usr/bin/env bash
# Unit tests of build.sh. docker and sbx are stubs that log their calls; SBX_STACK_CHECK replaces tests/check.sh.
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
out=$tmp/out
fails=0
rc=0
mkdir -p "$bin" "$work"

# The docker stub: "image inspect <ref>" succeeds for the refs in STUB_IMAGES, the images that exist before the run.
# "image inspect <ref> --format" prints a size: build.sh asks it only for the image it built.
# "build" fails with STUB_BUILD_FAIL=1.
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_LOG"
case "$1 ${2:-}" in
  "image inspect")
    if [ "${4:-}" = --format ]; then
      echo 1000000
      exit 0
    fi
    case " ${STUB_IMAGES:-} " in
      *" $3 "*) ;;
      *) exit 1 ;;
    esac
    ;;
  build\ *) [ "${STUB_BUILD_FAIL:-0}" -eq 0 ] ;;
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

# build <VAR=value>... -- <build.sh arguments>: runs build.sh with the stubs; sets rc, $calls and $out.
build() {
  local envs=("PATH=$bin:$PATH" "STUB_LOG=$calls")
  while [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  : >"$calls"
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

called() { grep -qF -- "$1" "$calls"; }
not_called() { ! grep -qF -- "$1" "$calls"; }
times() { [ "$(grep -cF -- "$2" "$calls")" -eq "$1" ]; }
said() { grep -qF -- "$1" "$out"; }
exit_is() { [ "$rc" -eq "$1" ]; }

build SBX_STACK_CHECK=true "STUB_IMAGES=$tag" --
expect "check passes: exit 0" exit_is 0
expect "check passes: the build pulls the base" called "docker build --pull"
expect "check passes: one template load" times 1 "sbx template load"
expect "check passes: the replaced image becomes previous" called "docker tag sbx-stack-base:replaced sbx-stack-base:previous"
expect "check passes: prints versions.txt" called "versions.txt"
expect "check passes: the replaced tag goes" called "docker image rm sbx-stack-base:replaced"

build SBX_STACK_CHECK=true --
expect "check passes, no image before: exit 0" exit_is 0
expect "check passes, no image before: no previous tag" not_called "sbx-stack-base:previous"

for run in first second; do
  build SBX_STACK_CHECK=false "STUB_IMAGES=$tag" --
  expect "check fails ($run run): exit 1" exit_is 1
  expect "check fails ($run run): the replaced image gets the tag again" called "docker tag sbx-stack-base:replaced $tag"
  expect "check fails ($run run): two template loads" times 2 "sbx template load"
  expect "check fails ($run run): previous stays" not_called "sbx-stack-base:previous"
  expect "check fails ($run run): says restored" said "restored"
done

build SBX_STACK_CHECK=false --
expect "check fails, no image before: exit 1" exit_is 1
expect "check fails, no image before: one template load" times 1 "sbx template load"
expect "check fails, no image before: says so" said "no earlier image to restore"

build SBX_STACK_CHECK=true STUB_BUILD_FAIL=1 "STUB_IMAGES=$tag" --
expect "the build fails: exit 1" exit_is 1
expect "the build fails: no template load" not_called "sbx template load"
expect "the build fails: no image save" not_called "docker image save"
expect "the build fails: the replaced tag goes" called "docker image rm sbx-stack-base:replaced"

build "STUB_IMAGES=sbx-stack-base:previous" -- --rollback
expect "rollback: exit 0" exit_is 0
expect "rollback: previous gets the tag" called "docker tag sbx-stack-base:previous $tag"
expect "rollback: one template load" times 1 "sbx template load"
expect "rollback: no build" not_called "docker build"

build -- --rollback
expect "rollback, no previous image: exit 1" exit_is 1
expect "rollback, no previous image: no template load" not_called "sbx template load"

build -- --force
expect "an unknown argument: exit 2" exit_is 2
expect "an unknown argument: usage" said "usage: build.sh [--rollback]"

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
passed=1
