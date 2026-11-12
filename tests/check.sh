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
tools="zsh eza zoxide starship btop fzf rg fd bat shfmt gitleaks file yazi ya wt lazygit lazydocker"
recorded="claude-code zsh oh-my-zsh fast-syntax-highlighting fzf-tab yazi wt lazygit lazydocker nvim tree-sitter rust LazyVim lazy.nvim"
email=$(git config --global --get user.email || true)
tmp=$(mktemp -d)
log=$tmp/log
overlay=$tmp/template.yaml
fails=0

printf 'sandboxOptions:\n  template: %s\n  pullPolicy: never\n' "$tag" >"$overlay"

# When bash stops the script on an unset variable, it exits with the status of this trap, so the trap fails unless
# the script reached its end.
passed=0
cleanup() {
  sbx env rm --force --no-input --name "$name" "$repo/tests/sbxenv.yaml" "$overlay" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  [ "$passed" -eq 1 ] || exit 1
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

# nvim_check <what> <lua>: runs the Lua in a headless nvim with the LazyVim config. Headless nvim writes its messages
# to stderr, so the check also fails on any message.
nvim_check() {
  local err rc=0
  err=$(sbx exec "$name" nvim --headless "+lua $2" +qa 2>&1 >/dev/null) || rc=$?
  [ -z "$err" ] || {
    rc=1
    printf '  nvim stderr: %s\n' "$err"
  }
  result "$rc" "$1"
}

# The sandbox's blocked requests to the hosts of a plugin or parser download, as "host count" lines.
blocked_downloads() {
  sbx policy log "$name" --json |
    jq -r '.blocked[] | select(.host | test("^(github\\.com|api\\.github\\.com|objects\\.githubusercontent\\.com|registry\\.npmjs\\.org):")) | "\(.host) \(.count)"' |
    sort
}

# run_lua <file in $tmp>: runs the repo's nvim-build/run-lua on the file in an offline container of the image.
run_lua() {
  docker run --rm --pull never --network none --entrypoint sh -v "$repo/layers/nvim/run-lua:/tmp/run-lua:ro" \
    -v "$tmp/$1:/tmp/t.lua:ro" "$tag" /tmp/run-lua /tmp/t.lua >>"$log" 2>&1
}

assertions() {
  local suffix=$1 t h p out rc before after
  check "zsh is the login shell$suffix" '[ "$(getent passwd agent | cut -d: -f7)" = /usr/bin/zsh ]'
  check "zsh loads oh-my-zsh$suffix" "[ \"\$(zsh -lic 'echo \$ZSH' 2>/dev/null | tail -1)\" = $share/oh-my-zsh ]"
  # zsh needs a terminal for zle: the Mac's script gives sbx exec -it one. The terminal echoes the end of input as
  # "^D" and two backspaces, in some runs twice (1 run in 20 on 2026-11-11); tr drops the backspaces and the CRs, the
  # expansion drops every "^D".
  out=$(script -q /dev/null sbx exec -it "$name" zsh -lic true </dev/null 2>&1 | tr -d '\r\010') || true
  out=${out//'^D'/}
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
  check "nvim is 0.11.2 or newer$suffix" \
    "nvim --clean --headless '+lua os.exit(vim.version.lt(vim.version(), {0, 11, 2}) and 1 or 0)'"
  check "zsh has y and wt as functions or commands$suffix" \
    '[ "$(zsh -lic "whence -w y wt" 2>/dev/null | grep -cE ": (function|command)$")" -eq 2 ]'
  check "zsh has the direnv hook$suffix" "zsh -lic 'typeset -f _direnv_hook >/dev/null' 2>/dev/null"
  before=$(blocked_downloads)
  # nvim-treesitter's own parser folder: Neovim's bundled parsers (c, lua, markdown, vim, vimdoc) do not count.
  nvim_check "nvim-treesitter has every parser of LazyVim's list$suffix" \
    'local have = require("nvim-treesitter").get_installed("parsers"); for _, l in ipairs(LazyVim.opts("nvim-treesitter").ensure_installed) do assert(vim.list_contains(have, l), "no parser: " .. l) end'
  nvim_check "nvim knows more than 20 plugins$suffix" 'assert(#require("lazy").plugins() > 20)'
  nvim_check "blink.cmp has its Rust matcher$suffix" 'assert(require("blink.cmp").library_available(), "no Rust matcher")'
  after=$(blocked_downloads)
  rc=0
  [ "$before" = "$after" ] || {
    rc=1
    printf '  blocked before:\n%s\n  blocked after:\n%s\n' "$before" "$after"
  }
  result "$rc" "the nvim runs make no request to GitHub or npm$suffix"
  check "COLORTERM is truecolor$suffix" "[ \"\$(zsh -lic 'echo \$COLORTERM' 2>/dev/null | tail -1)\" = truecolor ]"
  check "the .config folder belongs to agent$suffix" '[ "$(stat -c %U ~/.config)" = agent ]'
  check "git aliases$suffix" '[ -n "$(git config --get alias.st)" ]'
  if [ -n "$email" ]; then
    check "git user.email from the build$suffix" "[ \"\$(git config --system --get user.email)\" = '$email' ]"
  else
    check "git user.email unset$suffix" '! git config --system --get user.email'
  fi
  check "managed settings parse$suffix" "jq -e 'type == \"object\"' $managed"
  check "the default model is Opus 5.5 with high effort$suffix" \
    "jq -e '.model == \"claude-opus-5-5\" and .effortLevel == \"high\"' $managed"
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
  for t in $recorded $plugins; do
    check "versions.txt names $t$suffix" "grep -q ' $t ' $share/versions.txt"
  done
  check "every line of versions.txt has a layer, a name and a version$suffix" \
    "! grep -qvE '^[^ ]+ [^ ]+ [^ ]+\$' $share/versions.txt"
  check "the image version file$suffix" "[ \"\$(cut -d' ' -f1 $share/VERSION)\" = $version ]"
  check "github.com is closed at runtime$suffix" \
    "[ \"\$(curl -sS -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null || true)\" != 200 ]"
}

rc=0
docker run --rm --entrypoint sh "$tag" -c 'test ! -e /home/agent/.claude/.credentials.json' >>"$log" 2>&1 || rc=$?
result "$rc" "the image holds no Claude credentials file"

rc=0
docker run --rm --entrypoint sh "$tag" -c \
  '[ -z "$(find /home/agent/.local/share/nvim/lazy -mindepth 2 -maxdepth 2 -name target -type d 2>/dev/null)" ]' \
  >>"$log" 2>&1 || rc=$?
result "$rc" "the image holds no cargo build files"

rc=0
docker run --rm --entrypoint sh "$tag" -c \
  '! command -v cargo rustc tree-sitter && [ ! -e /home/agent/.cargo ] && [ ! -e /home/agent/.rustup ]' \
  >>"$log" 2>&1 || rc=$?
result "$rc" "the image holds no Rust and no tree-sitter CLI"

rc=0
docker run --rm --entrypoint sh "$tag" -c \
  '[ -z "$(find /home/agent/.config /home/agent/.local/share/nvim /home/agent/.claude/plugins ! -user agent -print -quit)" ]' \
  >>"$log" 2>&1 || rc=$?
result "$rc" "the agent owns every file in .config, .local/share/nvim and .claude/plugins"

# The build's verify step runs through run-lua: an error in the Lua must fail the step.
printf 'error("raised on purpose")\n' >"$tmp/raise.lua"
printf 'os.exit(1)\n' >"$tmp/exit1.lua"
printf 'vim.g.run_lua_clean = true\n' >"$tmp/clean.lua"
rc=0
run_lua raise.lua && rc=1
run_lua exit1.lua && rc=1
run_lua clean.lua || rc=1
result "$rc" "run-lua fails on a Lua error and on os.exit(1), and passes a clean file"

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
passed=1
