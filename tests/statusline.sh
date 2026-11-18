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

# The constants of the script.
band=$'\033[48;2;18;60;140m'
light=$'\033[38;2;235;238;245m'
fill=' '
reset=$'\033[0m'

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
input_json 日本語 >"$tmp/wide.json"
input=$tmp/input.json
path=$bin

# A quota engine that gives a verdict for both windows.
cat >"$tmp/engine" <<'EOF'
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
# each_row <test> [argument...]: the test holds for each of the three rows. The row number is the last argument.
each_row() {
  local n
  for n in 1 2 3; do
    "$@" "$n" || return 1
  done
}
row_has() { [[ "$(row "$1")" == *"$2"* ]]; }
starts_with() { [[ "$(row "$2")" == "$1"* ]]; }
ends_with() { [[ "$(row "$2")" == *"$1" ]]; }
# ends_with_fill <n>: the row has fill characters before its last reset.
ends_with_fill() { [[ "$(row "$1")" == *"$fill$reset" ]]; }
# no_reset_without_band <n>: after each reset in the row but the last one, the band and its text color are set
# again.
no_reset_without_band() {
  local text
  text=$(row "$1")
  text=${text%"$reset"}
  text=${text//"$reset$band$light"/}
  [[ "$text" != *"$reset"* ]]
}
# width <n>: the visible width of the row. This count is apart from the count of the script: a color code counts 0,
# a character with East Asian width W or F counts 2, a character before U+FE0F counts 2, U+FE0F and a combining
# character count 0, each other character counts 1.
cat >"$tmp/width.py" <<'EOF'
import re
import sys
import unicodedata

text = re.sub("\033\\[[0-9;]*m", "", sys.stdin.buffer.read().decode("utf-8").rstrip("\n"))
total = 0
VS16 = chr(0xFE0F)
for at, char in enumerate(text):
    if char == VS16 or unicodedata.combining(char):
        continue
    after = text[at + 1 : at + 2]
    total += 2 if unicodedata.east_asian_width(char) in ("W", "F") or after == VS16 else 1
print(total)
EOF
width() { row "$1" | python3 "$tmp/width.py"; }
width_is() { [ "$(width "$2")" -eq "$1" ]; }

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
expect "sandbox: three rows" rows_are 3
expect "sandbox: the chip names instance and sandbox" row_has 1 "📦 inst · box"
expect "sandbox: no profile chip" not said "👤"
expect "sandbox: each row starts with the band" each_row starts_with "$band"
expect "sandbox: plain text is light on the band" each_row starts_with "$band$light"
expect "sandbox: each row has the width COLUMNS less the margin" each_row width_is 118
expect "sandbox: the band is set again after each reset in a row" each_row no_reset_without_band
expect "sandbox: each row ends with a reset" each_row ends_with "$reset"
expect "sandbox: each row is filled" each_row ends_with_fill
expect "sandbox: no dim text on the band" not said $'\033[2m'
expect "sandbox: the session name stays" row_has 1 "fix-login"
expect "sandbox: the folder stays" row_has 2 "📁 app"
expect "sandbox: the cost stays" row_has 3 "\$1.42"

echo "== the label"
draw IS_SANDBOX=1 SANDBOX_NAME=box COLUMNS=120
expect "no label: the chip shows ?" row_has 1 "📦 ? · box"
draw IS_SANDBOX=1 SANDBOX_NAME=box SBX_INSTANCE= COLUMNS=120
expect "an empty label: the chip shows ?" row_has 1 "📦 ? · box"
draw IS_SANDBOX=1 SBX_INSTANCE=inst COLUMNS=120
expect "no sandbox name: the chip says sandbox" row_has 1 "📦 inst · sandbox"

echo "== the width"
draw "${sandbox[@]}"
expect "no COLUMNS: three rows" rows_are 3
expect "no COLUMNS: not filled" each_row not ends_with_fill
expect "no COLUMNS: the band is behind the text" each_row starts_with "$band"
draw "${sandbox[@]}" COLUMNS=abc
expect "COLUMNS is no number: three rows" rows_are 3
expect "COLUMNS is no number: not filled" each_row not ends_with_fill
draw "${sandbox[@]}" COLUMNS=20
expect "a narrow terminal: three rows" rows_are 3
expect "a narrow terminal: row 1 is too wide, so it is not filled" not ends_with_fill 1
expect "a narrow terminal: row 3 is too wide, so it is not filled" not ends_with_fill 3
expect "a narrow terminal: not cut" row_has 3 '12m3s'
expect "a narrow terminal: the short row is filled to the width" width_is 18 2
draw "${sandbox[@]}" COLUMNS=200
expect "a wide terminal: each row has the width 198" each_row width_is 198
draw "${sandbox[@]}" COLUMNS=0120
expect "COLUMNS with a zero in front is a decimal number" each_row width_is 118
draw "${sandbox[@]}" COLUMNS=99999999999999999999
expect "COLUMNS is too large for a width: three rows" rows_are 3
expect "COLUMNS is too large for a width: not filled" each_row not ends_with_fill
input=$tmp/wide.json
draw "${sandbox[@]}" COLUMNS=120
expect "a wide character: the name is in the row" row_has 1 "日本語"
expect "a wide character counts two columns" each_row width_is 118
input=$tmp/input.json

echo "== the quota bars"
draw "${sandbox[@]}" COLUMNS=160 "QUOTA_ENGINE=$tmp/engine"
expect "the quota bars keep their colors" said $'\033[38;2;240;240;240;48;2;35;165;75m'
expect "with quota bars: the width is right" each_row width_is 158
expect "with quota bars: the band is set again after each reset" each_row no_reset_without_band

echo "== no code from the working folder"
# The status line runs in the folder of a project. A file there with the name of a python module must not run.
for module in re unicodedata; do
  echo "open('$tmp/hijack', 'w')" >"$work/$module.py"
done
draw "${sandbox[@]}" COLUMNS=120
expect "a python module in the working folder does not run" [ ! -e "$tmp/hijack" ]
expect "a python module in the working folder: the rows are filled" each_row width_is 118
rm -f "$work"/*.py "$tmp/hijack"
mkdir "$tmp/modules"
echo "open('$tmp/hijack', 'w')" >"$tmp/modules/re.py"
draw "${sandbox[@]}" COLUMNS=120 "PYTHONPATH=$tmp/modules"
expect "a python module of PYTHONPATH does not run" [ ! -e "$tmp/hijack" ]
rm -f "$tmp/hijack"

echo "== no python3"
path=$nopy
draw "${sandbox[@]}" COLUMNS=120
expect "no python3: three rows, exit 0" rows_are 3
expect "no python3: the chip" row_has 1 "📦 inst · box"
expect "no python3: the band is behind the text" each_row starts_with "$band"
expect "no python3: the band is set again after each reset" each_row no_reset_without_band
expect "no python3: each row ends with a reset" each_row ends_with "$reset"
expect "no python3: not filled" each_row not ends_with_fill
draw
expect "no python3, not in a sandbox: the output of today" same_bytes "$out" "$expected"
path=$bin

echo "$((count - fails)) of $count passed"
[ "$fails" -eq 0 ]
