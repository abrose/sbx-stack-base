#!/usr/bin/env bash
# Creates check-base from the loaded template sbx-stack-base:<VERSION>, asserts with sbx exec, asserts again after a
# stop and start, and removes the sandbox. Run build.sh first.
# The single-quoted scripts run in the VM: their $ must stay literal here.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
version=$(cat "$repo/VERSION")
tag=sbx-stack-base:$version
name=check-base
share=/usr/local/share/sbx-stack
managed=/etc/claude-code/managed-settings.json
hooks="block-secret-exposure.mjs block-complex-bash.mjs block-agent-attribution.mjs block-protected-force-push.mjs
block-inline-interpreter.mjs warn-if-no-gitleaks.sh"
plugins="adhd-friendly-simple-technical-english@abrose-plugins quota-statusline@abrose-plugins
hookify@claude-plugins-official superpowers@claude-plugins-official"
tools="zsh eza zoxide starship btop fzf rg fd bat shfmt gitleaks"
email=$(git config --global --get user.email || true)
tmp=$(mktemp -d)
log=$tmp/log
overlay=$tmp/template.yaml
fails=0

printf 'sandboxOptions:\n  template: %s\n  pullPolicy: never\n' "$tag" >"$overlay"

cleanup() {
  sbx env rm --force --no-input --name "$name" "$repo/tests/sbxenv.yaml" "$overlay" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

result() {
  if [ "$1" -eq 0 ]; then
    echo "PASS $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

# check <what> <sh script>
check() {
  local rc=0
  sbx exec "$name" sh -c "$2" >>"$log" 2>&1 || rc=$?
  result "$rc" "$1"
}

assertions() {
  local suffix=$1 t h p out rc
  check "zsh is the login shell$suffix" '[ "$(getent passwd agent | cut -d: -f7)" = /usr/bin/zsh ]'
  check "zsh loads oh-my-zsh$suffix" "[ \"\$(zsh -lic 'echo \$ZSH' 2>/dev/null | tail -1)\" = $share/oh-my-zsh ]"
  # zsh needs a terminal for zle: the Mac's script gives sbx exec -it one. The terminal echoes the end of input as
  # "^D" and two backspaces; tr drops the backspaces and the CRs, the expansion drops the "^D".
  out=$(script -q /dev/null sbx exec -it "$name" zsh -lic true </dev/null 2>&1 | tr -d '\r\010') || true
  out=${out#'^D'}
  printf '%s\n' "$out" >>"$log"
  rc=0
  [ -z "$out" ] || {
    rc=1
    printf '  zsh output: %q\n' "$out"
  }
  result "$rc" "zsh starts with no output$suffix"
  for t in $tools; do
    check "$t runs$suffix" "$t --version >/dev/null"
  done
  check "direnv runs$suffix" 'direnv version >/dev/null'
  check "COLORTERM is truecolor$suffix" "[ \"\$(zsh -lic 'echo \$COLORTERM' 2>/dev/null | tail -1)\" = truecolor ]"
  check "git aliases$suffix" '[ -n "$(git config --get alias.st)" ]'
  if [ -n "$email" ]; then
    check "git user.email from the build$suffix" "[ \"\$(git config --system --get user.email)\" = '$email' ]"
  else
    check "git user.email unset$suffix" '! git config --system --get user.email'
  fi
  check "managed settings parse$suffix" "jq -e 'type == \"object\"' $managed"
  check "claude starts$suffix" 'claude --version'
  for p in $plugins; do
    check "plugin $p installed and enabled$suffix" "claude plugin list 2>&1 | grep -A3 -F '$p' | grep -qi enabled"
  done
  for h in $hooks; do
    check "hook $h exists and is in the managed settings once$suffix" \
      "test -f $share/claude/hooks/$h && [ \"\$(grep -o 'hooks/$h' $managed | wc -l)\" -eq 1 ]"
  done
  check "the statusline runs no quota engine from the current folder$suffix" \
    "d=\$(mktemp -d) && cd \$d && e=sbx/$name/plugins/marketplaces/abrose-plugins/plugins/quota-statusline/bin && mkdir -p \$e \
    && echo 'open(\"/tmp/statusline-hijack\", \"w\")' > \$e/quota-statusline \
    && { echo '{}' | SANDBOX_NAME=$name $share/claude/statusline >/dev/null 2>&1 || true; } && ! test -e /tmp/statusline-hijack"
  check "the image version file$suffix" "[ \"\$(cut -d' ' -f1 $share/VERSION)\" = $version ]"
  check "github.com is closed at runtime$suffix" \
    "[ \"\$(curl -sS -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null || true)\" != 200 ]"
}

rc=0
docker run --rm --entrypoint sh "$tag" -c 'test ! -e /home/agent/.claude/.credentials.json' >>"$log" 2>&1 || rc=$?
result "$rc" "the image holds no Claude credentials file"

start=$SECONDS
if ! sbx env create --force --no-input --name "$name" "$repo/tests/sbxenv.yaml" "$overlay" >"$log" 2>&1; then
  tail -20 "$log"
  echo "FAIL create $name"
  exit 1
fi
echo "created $name in $((SECONDS - start))s"

assertions ""
sbx stop "$name" >>"$log" 2>&1
# The first exec after a stop starts the sandbox and prints sbx's own "started" line; keep it out of the zsh check.
sbx exec "$name" true >>"$log" 2>&1
assertions " (after stop and start)"

[ "$fails" -eq 0 ] || {
  echo "$fails failed"
  exit 1
}
echo "all passed"
