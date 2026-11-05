#!/usr/bin/env bash
# The single-quoted scripts run in the VM: their $ must stay literal here.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
name=check-base
nomkt=check-base-nomkt
env_file=$repo/tests/sbxenv.yaml
nomkt_file=$repo/tests/sbxenv-nomkt.yaml
share=/usr/local/share/sbx-stack
hooks="block-secret-exposure.mjs block-complex-bash.mjs block-agent-attribution.mjs block-protected-force-push.mjs
block-inline-interpreter.mjs warn-if-no-gitleaks.sh"
plugins="adhd-friendly-simple-technical-english@abrose-plugins quota-statusline@abrose-plugins
hookify@claude-plugins-official superpowers@claude-plugins-official caveman@caveman"
style=$(jq -r .outputStyle "$repo/files/claude/settings.json")
log=$(mktemp)
fails=0

cleanup() {
  sbx env rm --force --no-input --name "$name" "$env_file" >/dev/null 2>&1 || true
  sbx env rm --force --no-input --name "$nomkt" "$nomkt_file" >/dev/null 2>&1 || true
  rm -f "$log"
}
trap cleanup EXIT

# check <sandbox> <what> <sh script>
check() {
  if sbx exec "$1" sh -c "$3" >>"$log" 2>&1; then
    echo "PASS $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

create() {
  if ! sbx env create --force --no-input --name "$1" "$2" >"$log" 2>&1; then
    tail -20 "$log"
    echo "FAIL create $1"
    exit 1
  fi
}

hooks_once() {
  local h script=""
  for h in $hooks; do
    script="$script test -f $share/claude/hooks/$h && [ \"\$(grep -o 'hooks/$h' ~/.claude/settings.json | wc -l)\" -eq 1 ] &&"
  done
  check "$name" "$1" "$script true"
}

create "$name" "$env_file"

check "$name" "zsh is the login shell" '[ "$(getent passwd agent | cut -d: -f7)" = /usr/bin/zsh ]'
check "$name" "zsh loads oh-my-zsh" "[ \"\$(zsh -ic 'echo \$ZSH' 2>/dev/null | tail -1)\" = $share/oh-my-zsh ]"
check "$name" "git user.email from the kit arg" '[ "$(git config --get user.email)" = test@example.com ]'
check "$name" "git user.name from the kit arg" '[ "$(git config --get user.name)" = "Test User" ]'
check "$name" "git aliases" '[ -n "$(git config --get alias.st)" ]'
check "$name" "outputStyle from files/claude/settings.json" "[ \"\$(jq -r .outputStyle ~/.claude/settings.json)\" = '$style' ]"
check "$name" "statusLine runs the kit's statusline" \
  "[ \"\$(jq -r .statusLine.command ~/.claude/settings.json)\" = $share/claude/statusline ] && test -x $share/claude/statusline"
check "$name" "the statusline runs no quota engine from the current folder" \
  "d=\$(mktemp -d) && cd \$d && e=sbx/$name/plugins/marketplaces/abrose-plugins/plugins/quota-statusline/bin && mkdir -p \$e \
  && echo 'open(\"/tmp/statusline-hijack\", \"w\")' > \$e/quota-statusline \
  && { echo '{}' | SANDBOX_NAME=$name $share/claude/statusline >/dev/null 2>&1 || true; } && ! test -e /tmp/statusline-hijack"
for p in $plugins; do
  check "$name" "plugin $p installed" "claude plugin list 2>&1 | grep -qF '$p'"
done
hooks_once "each hook file exists and is in settings.json once"
check "$name" "github.com is closed at runtime" \
  "[ \"\$(curl -sS -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null || true)\" != 200 ]"

for i in 1 2 3; do
  sbx stop "$name" >>"$log" 2>&1
  hooks_once "hooks once after stop and start $i"
done
for p in $plugins; do
  check "$name" "plugin $p enabled after stop and start" \
    "jq -e --arg p '$p' '.enabledPlugins[\$p] == true' ~/.claude/settings.json >/dev/null"
done

create "$nomkt" "$nomkt_file"
check "$nomkt" "a bogus marketplace does not block the sandbox" 'claude plugin list >/dev/null 2>&1'
check "$nomkt" "plugins.log has the failed marketplace add" \
  "grep -E '^marketplace add bogus .* rc=[1-9]' ~/.sbx-stack/plugins.log"

[ "$fails" -eq 0 ]
