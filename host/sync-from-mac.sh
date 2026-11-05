#!/usr/bin/env bash
# Copies the owner's starship config, Claude statusline, hooks and settings from the Mac into files/, the recipe's
# source (the VM gets files/ at /usr/local/share/sbx-stack). A maintenance tool: run it by hand, review the diff,
# commit. No sandbox calls it.
# Usage: host/sync-from-mac.sh <claude config dir with settings.json and statusline.sh>
set -euo pipefail

[ $# -eq 1 ] && [ -f "$1/settings.json" ] || {
  echo "usage: $0 <claude config dir with settings.json and statusline.sh>" >&2
  exit 2
}
claude=$(cd "$1" && pwd)
repo=$(cd "$(dirname "$0")/.." && pwd)
hooks_src=$HOME/.claude/hooks
share=$repo/files/claude
vm_share=/usr/local/share/sbx-stack/claude
hooks=(block-secret-exposure.mjs block-complex-bash.mjs block-agent-attribution.mjs block-protected-force-push.mjs
  block-inline-interpreter.mjs warn-if-no-gitleaks.sh)
libs=(shell-ast.mjs gopass-shell-ast.mjs)

mkdir -p "$share/hooks"
cp "$HOME/.config/starship.toml" "$repo/files/starship.toml"
for f in "${hooks[@]}" "${libs[@]}"; do
  cp "$hooks_src/$f" "$share/hooks/$f"
done
cp "$claude/statusline.sh" "$share/statusline.sh"

jq --arg from "$hooks_src/" --arg to "$vm_share/hooks/" --arg sl "$vm_share/statusline" \
  --argjson keep "$(printf '%s\n' "${hooks[@]}" | jq -Rn '[inputs]')" '
  ({outputStyle, tui} | with_entries(select(.value != null)))
  + {statusLine: {type: "command", command: $sl}}
  + {hooks: (.hooks // {}
      | map_values(map(.hooks |= map(select(.command as $c | any($keep[]; . as $k | $c | contains($from + $k)))))
          | map(select(.hooks != [])))
      | with_entries(select(.value != []))
      | walk(if type == "string" then split($from) | join($to) else . end))}
  ' "$claude/settings.json" >"$share/settings.json"

for f in "${hooks[@]}"; do
  [ "$(grep -cF "$vm_share/hooks/$f" "$share/settings.json")" -eq 1 ] || {
    echo "hook not in the settings exactly once: $f" >&2
    exit 1
  }
done
! grep -rqF "$HOME" "$repo/files" || {
  echo "a Mac home path is left in files/:" >&2
  grep -rlF "$HOME" "$repo/files" >&2
  exit 1
}
gitleaks dir "$repo/files" --redact --no-banner
