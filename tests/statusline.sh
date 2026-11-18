#!/usr/bin/env bash
# Unit tests of layers/claude/statusline.sh, on the Mac. The script runs with an empty environment, a fixed input,
# a HOME and a working folder below a temporary folder, and a PATH that holds only the tools that it needs.
# tests/statusline.expected is the output for a session that is not in a sandbox. To write it new after a wanted
# change of that output: STATUSLINE_PIN=1 bash tests/statusline.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
script=$root/layers/claude/statusline.sh
expected=$root/tests/statusline.expected
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
home=$tmp/home
work=$tmp/work/app
bin=$tmp/bin
nopy=$tmp/nopy
out=$tmp/out
err=$tmp/err
mkdir -p "$home" "$work" "$bin" "$nopy"
for tool in cat jq git; do
  ln -s "$(command -v "$tool")" "$bin/$tool"
  ln -s "$(command -v "$tool")" "$nopy/$tool"
done
# The interpreter itself: a python3 in PATH can be a shim script that needs more than this PATH holds.
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$bin/python3"

# The constants of the script: the colors of the instances, and gray for a sandbox with no label.
palette=("45;170;160" "230;165;40" "155;115;215" "215;95;125" "80;150;225" "150;190;70")
gray="120;120;125"
reset=$'\033[0m'
dim=$'\033[2m'
# color_of <instance>: the color of the instance. The rule: the sum of the bytes of the name, modulo the size of
# the palette. Counted here with python, apart from the count of the script.
color_of() {
  case "$1" in
    '' | '?') echo "$gray" ;;
    *) echo "${palette[$(python3 -c 'import sys; print(sum(sys.argv[1].encode()) % 6)' "$1")]}" ;;
  esac
}
stripe_of() { printf '\033[38;2;%sm▌\033[0m ' "$1"; }
pill_of() { printf '\033[1;38;2;20;20;20;48;2;%sm' "$1"; }

# input_json <session name>: the payload that Claude Code gives a status line.
input_json() {
  cat <<EOF
{"model":{"display_name":"Opus 5.5"},"workspace":{"current_dir":"/work/app"},
 "cost":{"total_cost_usd":1.4234,"total_duration_ms":723000},"output_style":{"name":"Explanatory"},
 "effort":{"level":"high"},"session_id":"1a2b3c4d-0000-0000-0000-000000000000","session_name":"$1",
 "context_window":{"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":20000,"cache_read_input_tokens":99000}}}
EOF
}
input_json fix-login >"$tmp/input.json"
input=$tmp/input.json
path=$bin

# A quota engine that gives a verdict for both windows. It imports a standard module, so a module of the same name
# in the working folder would run if python looked there.
cat >"$tmp/engine" <<'EOF'
import re
print('{"5h": {"severity": "ok", "info": "3h", "used_pct": 42}, "7d": {"severity": "ok", "info": "5d", "used_pct": 18}}')
EOF

# draw [VAR=value]...: runs the script with these variables. The rows go to $out.
draw() {
  rc=0
  (cd "$work" && exec env -i "HOME=$home" "PATH=$path" "$@" "$BASH" "$script") <"$input" >"$out" 2>"$err" || rc=$?
}

count=0
fails=0
expect() {
  local title=$1
  shift
  count=$((count + 1))
  if "$@"; then
    echo "PASS $title"
  else
    echo "FAIL $title"
    fails=$((fails + 1))
  fi
}
not() { ! "$@"; }
row() { sed -n "${1}p" "$out"; }
rows_are() { [ "$(wc -l <"$out" | tr -d ' ')" -eq "$1" ] && [ "$rc" -eq 0 ]; }
said() { grep -qF -- "$1" "$out"; }
same_bytes() { cmp -s "$1" "$2"; }
keep() { cp "$out" "$tmp/$1"; }
row_has() { [[ "$(row "$1")" == *"$2"* ]]; }
starts_with() { [[ "$(row "$2")" == "$1"* ]]; }
# each_row <test> [argument...]: the test holds for each of the three rows. The row number is the last argument.
each_row() {
  local n
  for n in 1 2 3; do
    "$@" "$n" || return 1
  done
}
# chip_is <instance> <sandbox>: row 1 starts with the stripe and the pill in the color of the instance.
chip_is() {
  local c
  c=$(color_of "$1")
  starts_with "$(stripe_of "$c")$(pill_of "$c") 📦 $1 · $2 $reset" 1
}
# as_on_the_mac <n>: row n is the row n of the Mac after the stripe. For row 1 the chips differ, so the part after
# the chip is compared.
as_on_the_mac() {
  local n=$1 c mac text
  c=$(color_of inst)
  mac=$(sed -n "${n}p" "$expected")
  text=$(row "$n")
  text=${text#"$(stripe_of "$c")"}
  if [ "$n" -eq 1 ]; then
    text=${text#"$(pill_of "$c") 📦 inst · box $reset"}
    mac=${mac#"${dim}👤 default${reset}"}
  fi
  [ "$text" = "$mac" ]
}

sandbox=(IS_SANDBOX=1 SANDBOX_NAME=box SBX_INSTANCE=inst)

if [ -n "${STATUSLINE_PIN:-}" ]; then
  draw
  cp "$out" "$expected"
  echo "wrote $expected"
  exit 0
fi

echo "== not in a sandbox"
draw
expect "no IS_SANDBOX: the output of today" same_bytes "$out" "$expected"
draw COLUMNS=120
expect "no IS_SANDBOX, with COLUMNS: the output of today" same_bytes "$out" "$expected"
draw IS_SANDBOX= SANDBOX_NAME=box SBX_INSTANCE=inst COLUMNS=120
expect "IS_SANDBOX is empty: the output of today" same_bytes "$out" "$expected"

echo "== in a sandbox"
draw "${sandbox[@]}" COLUMNS=120
keep sandbox.out
expect "sandbox: three rows, exit 0" rows_are 3
expect "sandbox: each row starts with the stripe in the color of the instance" \
  each_row starts_with "$(stripe_of "$(color_of inst)")"
expect "sandbox: the pill names instance and sandbox, in the color of the instance" chip_is inst box
expect "sandbox: no profile chip" not said "👤"
expect "sandbox: row 1 after the chip is the row of the Mac" as_on_the_mac 1
expect "sandbox: row 2 after the stripe is the row of the Mac" as_on_the_mac 2
expect "sandbox: row 3 after the stripe is the row of the Mac" as_on_the_mac 3

echo "== the color of an instance"
for name in alpha beta gamma delta epsilon zeta default check; do
  draw IS_SANDBOX=1 SANDBOX_NAME=box "SBX_INSTANCE=$name"
  expect "the instance $name has its color" chip_is "$name" box
done
expect "the palette gives the instances different colors" \
  [ "$(for n in alpha beta gamma delta epsilon zeta; do color_of "$n"; done | sort -u | wc -l | tr -d ' ')" -gt 3 ]

echo "== the label"
draw IS_SANDBOX=1 SANDBOX_NAME=box
expect "no label: a gray pill with ?" chip_is "?" box
draw IS_SANDBOX=1 SANDBOX_NAME=box SBX_INSTANCE=
expect "an empty label: a gray pill with ?" chip_is "?" box
draw IS_SANDBOX=1 SBX_INSTANCE=inst
expect "no sandbox name: the pill says sandbox" chip_is inst sandbox

echo "== the width does not count"
for columns in "" abc 20 200; do
  draw "${sandbox[@]}" "COLUMNS=$columns"
  expect "COLUMNS=$columns: the same rows as with 120" same_bytes "$out" "$tmp/sandbox.out"
done

echo "== the quota bars"
draw "${sandbox[@]}" "QUOTA_ENGINE=$tmp/engine"
expect "the quota bars keep their colors" said $'\033[38;2;240;240;240;48;2;35;165;75m'
expect "with quota bars: each row starts with the stripe" each_row starts_with "$(stripe_of "$(color_of inst)")"

echo "== no code from the working folder"
# The status line runs in the folder of a project. A file there with the name of a python module must not run.
echo "open('$tmp/hijack', 'w')" >"$work/re.py"
draw "${sandbox[@]}" "QUOTA_ENGINE=$tmp/engine"
expect "a python module in the working folder does not run" [ ! -e "$tmp/hijack" ]
rm -f "$work/re.py" "$tmp/hijack"

echo "== no python3"
path=$nopy
draw "${sandbox[@]}" COLUMNS=120
expect "no python3: the same rows" same_bytes "$out" "$tmp/sandbox.out"
draw
expect "no python3, not in a sandbox: the output of today" same_bytes "$out" "$expected"
path=$bin

echo "$((count - fails)) of $count passed"
[ "$fails" -eq 0 ]
