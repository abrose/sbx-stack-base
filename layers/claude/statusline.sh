#!/bin/bash
# Claude Code statusline: renders a 3-line status. The quota projection is
# delegated to the quota-statusline engine (the abrose-plugins marketplace);
# this script locates it, pipes the payload in once, and renders the JSON
# verdict it prints. The engine also logs the rolling usage sample.
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
STYLE=$(echo "$input" | jq -r '.output_style.name // empty')
STYLE="${STYLE:0:20}"
EFFORT=$(echo "$input" | jq -r '.effort.level // empty')
SID=$(echo "$input" | jq -r '.session_id // empty')
SID_SHORT="${SID:0:8}"
SNAME=$(echo "$input" | jq -r '.session_name // empty')

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
MAGENTA='\033[35m'; DIM='\033[2m'

# Current Claude profile (from CLAUDE_CONFIG_DIR; "default" when unset or ~/.claude)
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ "$CONFIG_DIR" = "$HOME/.claude" ]; then
  PROFILE="default"; PROFILE_COLOR=$DIM
else
  PROFILE="${CONFIG_DIR##*/}"; PROFILE_COLOR=$MAGENTA
fi

# Locate the quota engine inside Claude Code's marketplace clone. Resolve for
# this profile first (CLAUDE_CONFIG_DIR), then the default profile; QUOTA_ENGINE
# overrides both (tests). A missing engine means no quota segments, no error.
REL="plugins/marketplaces/abrose-plugins/plugins/quota-statusline/bin/quota-statusline"
ENGINE=""
for cand in "${QUOTA_ENGINE:-}" "$CONFIG_DIR/$REL" "$HOME/.claude/$REL"; do
  if [ -n "$cand" ] && [ -f "$cand" ]; then ENGINE="$cand"; break; fi
done
VERDICT=""
[ -n "$ENGINE" ] && VERDICT=$(printf '%s' "$input" | python3 "$ENGINE" 2>/dev/null)

make_bar() {
  local pct=$1 width=${2:-10}
  local filled=$((pct * width / 100))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$((width - filled))
  local fill pad
  printf -v fill "%${filled}s"
  printf -v pad "%${empty}s"
  printf '%s' "${fill// /█}${pad// /░}"
}

# Map severity to an at-a-glance trajectory glyph.
icon() {
  case "$1" in
    max)  printf '🛑' ;;
    hot)  printf '🔥' ;;
    near) printf '⚠️' ;;
    warm) printf '⏳' ;;
    *)    printf '🟢' ;;
  esac
}

# Context bar (line 3): absolute tokens, which every turn re-reads. Fixed
# thresholds, not window percent: 70% of a 1M window is already 700k. The bar
# fills at 350k, the CLAUDE_CODE_AUTO_COMPACT_WINDOW set in settings.json; red
# starts just before compaction (the window minus its ~33k summary buffer).
CTX=$(echo "$input" | jq -r '.context_window.current_usage
  | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
  // 0')
CTX_K=$((CTX / 1000))
CTX_HINT=""
if   [ "$CTX_K" -ge 300 ]; then BAR_COLOR=$RED; CTX_HINT=" /clear?"
elif [ "$CTX_K" -ge 200 ]; then BAR_COLOR=$YELLOW
else                            BAR_COLOR=$GREEN
fi
BAR=$(make_bar $((CTX_K * 100 / 350)) 10)

MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))

BRANCH=""
git rev-parse --git-dir > /dev/null 2>&1 && BRANCH=" 🌿 $(git branch --show-current 2>/dev/null)"

# One window widget: label + two-layer bar + trajectory glyph, from the engine
# verdict for this window. The bar is a muted-green budget block; the used-% eats
# into it in the pace color (green under, amber near, red over). The label sits
# on the bar: used-% left-aligned, hours-to-reset right-aligned. The glyph
# repeats the verdict. Prints nothing when the window is absent from the verdict.
quota_segment() {
  local label=$1 w=18
  local sev info pct fillbg budbg fg left gap padded filled
  [ -n "$VERDICT" ] || return
  IFS=$'\t' read -r sev info pct < <(printf '%s' "$VERDICT" \
    | jq -r --arg w "$label" '.[$w] // empty | "\(.severity)\t\(.info)\t\(.used_pct)"')
  [ -z "$sev" ] && return
  case "$sev" in
    max|hot) fillbg='48;2;165;45;45'  ;;
    near)    fillbg='48;2;155;110;10' ;;
    warm)    fillbg='48;2;90;90;95'   ;;
    *)       fillbg='48;2;35;165;75'  ;;
  esac
  budbg='48;2;52;86;62'; fg='38;2;240;240;240'
  left="${pct}%"
  gap=$(( w - ${#left} - ${#info} ))
  [ "$gap" -lt 1 ] && gap=1
  printf -v padded '%s%*s%s' "$left" "$gap" '' "$info"
  padded=${padded:0:w}
  filled=$(( pct * w / 100 ))
  [ "$filled" -gt "$w" ] && filled=$w
  printf '%s \033[%s;%sm%s\033[%s;%sm%s\033[0m %s' \
    "$label" "$fg" "$fillbg" "${padded:0:filled}" "$fg" "$budbg" "${padded:filled}" "$(icon "$sev")"
}

RIGHT_DISPLAY=""
seg=$(quota_segment 5h)
[ -n "$seg" ] && RIGHT_DISPLAY="$seg"
seg=$(quota_segment 7d)
if [ -n "$seg" ]; then
  [ -n "$RIGHT_DISPLAY" ] && RIGHT_DISPLAY="${RIGHT_DISPLAY}  "
  RIGHT_DISPLAY="${RIGHT_DISPLAY}${seg}"
fi

SID_DISPLAY=""
if [ -n "$SNAME" ] && [ -n "$SID_SHORT" ]; then
  SID_DISPLAY=" ${DIM}🆔 ${SNAME} · ${SID_SHORT}${RESET}"
elif [ -n "$SNAME" ]; then
  SID_DISPLAY=" ${DIM}🆔 ${SNAME}${RESET}"
elif [ -n "$SID_SHORT" ]; then
  SID_DISPLAY=" ${DIM}🆔 ${SID_SHORT}${RESET}"
fi

STYLE_CHIP=""
[ -n "$STYLE" ] && [ "$STYLE" != "default" ] && STYLE_CHIP=" | 🎨 ${STYLE}"

# Model chip carries the live effort level when the model supports it.
MODEL_CHIP="${CYAN}[$MODEL]${RESET}"
[ -n "$EFFORT" ] && MODEL_CHIP="${CYAN}[$MODEL${RESET}${DIM} · ${EFFORT}${RESET}${CYAN}]${RESET}"

# Line 1: identity + output style. Line 2: dir/branch chip. Line 3: metrics.
echo -e "${PROFILE_COLOR}👤 ${PROFILE}${RESET}${SID_DISPLAY} | ${MODEL_CHIP}${STYLE_CHIP}"
echo -e "📁 ${DIR##*/}${BRANCH}"

COST_FMT=$(printf '$%.2f' "$COST")
QUOTA_CHIP=""
[ -n "$RIGHT_DISPLAY" ] && QUOTA_CHIP=" | ${RIGHT_DISPLAY}"
echo -e "${BAR_COLOR}${BAR}${RESET} ${CTX_K}k${CTX_HINT} | ${YELLOW}${COST_FMT}${RESET} | ⏱️ ${MINS}m${SECS}s${QUOTA_CHIP}"
