#!/bin/bash
echo "Removing claude-statusline..."

# Kill watcher
kill $(cat /tmp/claude-proxy-watcher.pid 2>/dev/null) 2>/dev/null
rm -f /tmp/claude-proxy-state /tmp/claude-proxy-watcher.pid

# Remove files
rm -f "$HOME/.claude/statusline.sh" "$HOME/.claude/proxy-watcher.ts"

# Remove statusLine from settings.json
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && jq -e '.statusLine' "$SETTINGS" > /dev/null 2>&1; then
    TMP=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    echo "  statusLine removed from settings.json"
fi

echo "Done. Restart Claude Code."
