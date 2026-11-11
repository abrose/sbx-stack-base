#!/usr/bin/env bash
# The managed settings, the statusline, the safety hooks, and the plugins of plugins.txt at their newest version.
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=layers/lib.sh
. /layers/lib.sh

claude=/home/agent/.local/bin/claude

mkdir -p "$SBX_STACK/claude"
cp -R "$here/hooks" "$here/statusline" "$here/statusline.sh" "$here/managed-settings.json" "$SBX_STACK/claude/"
install -D -m 644 "$here/managed-settings.json" /etc/claude-code/managed-settings.json

while read -r kind name; do
  case $kind in
    marketplace) as_agent "$claude" plugin marketplace add "$name" </dev/null ;;
    plugin) as_agent "$claude" plugin install "$name" </dev/null ;;
  esac
done <"$here/plugins.txt"

# The plugin calls leave login and session files. They must not reach the image.
rm -rf /home/agent/.claude/.credentials.json /home/agent/.claude/sessions /home/agent/.claude/settings.json \
  /home/agent/.claude.json /home/agent/.claude.json.backup

version=$(as_agent "$claude" --version </dev/null)
record claude claude-code "${version%% *}"
installed=$(jq -r '.plugins | to_entries[] | "\(.key) \(.value[0].version)"' \
  /home/agent/.claude/plugins/installed_plugins.json)
while read -r name version; do
  record claude "$name" "$version"
done <<<"$installed"
