#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "Installing claude-statusline..."

# Check JSON parser — need at least one of: jq, python3, node
JSON_CMD=""
if command -v jq &>/dev/null; then JSON_CMD="jq"
elif command -v python3 &>/dev/null; then JSON_CMD="python3"
elif command -v node &>/dev/null; then JSON_CMD="node"
else
    echo "ERROR: Need jq, python3, or node for JSON parsing. Install one of them."
    exit 1
fi
echo "  JSON parser: $JSON_CMD"

# Ensure ~/.claude exists
mkdir -p "$CLAUDE_DIR"

# Copy files (symlinks break on some envs like Replit)
cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"
echo "  statusline.sh installed"

if command -v bun &>/dev/null; then
    cp "$SCRIPT_DIR/proxy-watcher.ts" "$CLAUDE_DIR/proxy-watcher.ts"
    chmod +x "$CLAUDE_DIR/proxy-watcher.ts"
    echo "  proxy-watcher installed (bun at $(command -v bun))"
else
    echo "  proxy-watcher skipped (no bun — proxy live stream won't show)"
fi

# Copy brand config if not already present
if [ ! -f "$HOME/.claude-statusline.conf" ] && [ -f "$SCRIPT_DIR/brand.conf.example" ]; then
    cp "$SCRIPT_DIR/brand.conf.example" "$HOME/.claude-statusline.conf"
    echo "  brand config created at ~/.claude-statusline.conf"
fi

# Patch settings.json — portable JSON merge (jq > python3 > node)
SETTINGS="$CLAUDE_DIR/settings.json"
SL_CONFIG='{"type":"command","command":"~/.claude/statusline.sh","padding":0}'

patch_settings() {
    if command -v jq &>/dev/null; then
        if jq -e '.statusLine' "$SETTINGS" > /dev/null 2>&1; then
            echo "  settings.json already has statusLine — skipping"
            return
        fi
        TMP=$(mktemp)
        jq --argjson sl "$SL_CONFIG" '. + {statusLine: $sl}' "$SETTINGS" > "$TMP"
        mv "$TMP" "$SETTINGS"
    elif command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
with open('$SETTINGS') as f: d = json.load(f)
if 'statusLine' in d:
    print('  settings.json already has statusLine — skipping')
    sys.exit(0)
d['statusLine'] = json.loads('$SL_CONFIG')
with open('$SETTINGS', 'w') as f: json.dump(d, f, indent=2)
"
    elif command -v node &>/dev/null; then
        node -e "
const fs=require('fs');
const d=JSON.parse(fs.readFileSync('$SETTINGS','utf8'));
if(d.statusLine){console.log('  settings.json already has statusLine — skipping');process.exit(0)}
d.statusLine=JSON.parse('$SL_CONFIG');
fs.writeFileSync('$SETTINGS',JSON.stringify(d,null,2));
"
    fi
}

if [ -f "$SETTINGS" ]; then
    patch_settings
    echo "  statusLine config merged into settings.json"
else
    if command -v python3 &>/dev/null; then
        python3 -c "
import json
with open('$SETTINGS', 'w') as f:
    json.dump({'statusLine': json.loads('$SL_CONFIG')}, f, indent=2)
"
    else
        echo "{\"statusLine\":$SL_CONFIG}" > "$SETTINGS"
    fi
    echo "  settings.json created"
fi

echo ""
echo "Done! Restart Claude Code to see the statusline."
echo ""
echo "Customize your brand:  ~/.claude-statusline.conf"
echo "Live proxy stream:     install bun (optional)"
