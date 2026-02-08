#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

echo "Installing claude-statusline..."

# Check deps
if ! command -v jq &>/dev/null; then
    echo "jq is required. Installing..."
    if command -v brew &>/dev/null; then
        brew install jq
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y jq 2>/dev/null || apt-get install -y jq
    elif command -v nix-env &>/dev/null; then
        nix-env -iA nixpkgs.jq
    else
        echo "ERROR: jq not found and no package manager detected. Install jq manually."
        exit 1
    fi
fi

# Ensure ~/.claude exists
mkdir -p "$CLAUDE_DIR"

# Copy files (symlinks break on some envs like Replit)
cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"

if command -v bun &>/dev/null; then
    cp "$SCRIPT_DIR/proxy-watcher.ts" "$CLAUDE_DIR/proxy-watcher.ts"
    chmod +x "$CLAUDE_DIR/proxy-watcher.ts"
    echo "  proxy-watcher installed (bun found at $(command -v bun))"
else
    echo "  proxy-watcher skipped (bun not found — proxy stats won't show)"
fi

# Copy brand config if not already present
if [ ! -f "$HOME/.claude-statusline.conf" ] && [ -f "$SCRIPT_DIR/brand.conf.example" ]; then
    cp "$SCRIPT_DIR/brand.conf.example" "$HOME/.claude-statusline.conf"
    echo "  brand config created at ~/.claude-statusline.conf"
fi

# Patch settings.json — add statusLine config (non-destructive)
SETTINGS="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS" ]; then
    # Check if statusLine already configured
    if jq -e '.statusLine' "$SETTINGS" > /dev/null 2>&1; then
        echo "  settings.json already has statusLine — skipping"
    else
        # Merge statusLine into existing settings
        TMP=$(mktemp)
        jq '. + {"statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "padding": 0}}' "$SETTINGS" > "$TMP"
        mv "$TMP" "$SETTINGS"
        echo "  statusLine added to settings.json"
    fi
else
    # Create minimal settings.json
    cat > "$SETTINGS" << 'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
EOF
    echo "  settings.json created with statusLine config"
fi

echo ""
echo "Done! Restart Claude Code to see the statusline."
echo ""
echo "Optional: customize your brand in ~/.claude-statusline.conf"
echo "Optional: install bun for live proxy reasoning stream"
