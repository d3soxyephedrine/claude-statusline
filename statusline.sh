#!/bin/bash
input=$(cat)

# Parse JSON input
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // "~"')
CONTEXT_USED=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# Effort level (env var — not in statusline input)
EFFORT="${CLAUDE_CODE_EFFORT_LEVEL:-high}"

# Permission mode (from settings.json — not in statusline input)
PERM_MODE=$(jq -r '.permissions.defaultMode // "default"' "$HOME/.claude/settings.json" 2>/dev/null)
[ -z "$PERM_MODE" ] && PERM_MODE="default"

# Directory — project substitutions (customize in ~/.claude-statusline.conf)
DIR_PATH="$CURRENT_DIR"
BRAND=""
if [ -f "$HOME/.claude-statusline.conf" ]; then
    source "$HOME/.claude-statusline.conf"
fi
# Default Ko2 substitution (override via conf)
if [ -z "$BRAND" ]; then
    case "$CURRENT_DIR" in
        "$HOME/projects/ko2"*)
            BRAND=$(printf "\033[1;97;48;5;91m ⚡Ko2 \033[0m")
            DIR_PATH="${CURRENT_DIR#$HOME/projects/ko2}"
            [ -z "$DIR_PATH" ] && DIR_PATH=""
            ;;
        "$HOME/projects/gpu-fleet"*) DIR_PATH="gpu${CURRENT_DIR#$HOME/projects/gpu-fleet}" ;;
        "$HOME"*) DIR_PATH="~${CURRENT_DIR#$HOME}" ;;
    esac
fi

# Git branch + dirty
GIT=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git -c advice.detachedHead=false branch --show-current 2>/dev/null)
    if [ -n "$BRANCH" ]; then
        DIRTY=""
        [ -n "$(git -c core.useBuiltinFSMonitor=false status --porcelain 2>/dev/null | head -1)" ] && DIRTY="!"
        GIT=$(printf " \033[1;35m %s%s\033[0m" "$BRANCH" "$DIRTY")
    fi
fi

# Context window bar ━━━━━━━━╌╌╌╌╌╌╌╌ 42%
CTX_BAR=""
if [ -n "$CONTEXT_USED" ]; then
    PCT=$(printf "%.0f" "$CONTEXT_USED")
    BAR_W=16
    FILLED=$(( (PCT * BAR_W + 50) / 100 ))
    [ "$FILLED" -gt "$BAR_W" ] && FILLED=$BAR_W
    EMPTY=$((BAR_W - FILLED))

    if [ "$PCT" -gt 75 ]; then CLR="31"
    elif [ "$PCT" -gt 50 ]; then CLR="33"
    else CLR="32"; fi

    BAR_FILLED="" BAR_EMPTY=""
    for ((i=0; i<FILLED; i++)); do BAR_FILLED+="━"; done
    for ((i=0; i<EMPTY; i++)); do BAR_EMPTY+="╌"; done

    CTX_BAR=$(printf " \033[${CLR}m%s\033[2;${CLR}m%s\033[0m \033[${CLR}m%d%%\033[0m" "$BAR_FILLED" "$BAR_EMPTY" "$PCT")
fi

# Effort badge
case "$EFFORT" in
    max)  EFFORT_BADGE=$(printf "\033[1;97;48;5;208m max \033[0m") ;;
    high) EFFORT_BADGE=$(printf "\033[1;97;48;5;28m high \033[0m") ;;
    low)  EFFORT_BADGE=$(printf "\033[2m low \033[0m") ;;
    *)    EFFORT_BADGE=$(printf "\033[2m%s\033[0m" "$EFFORT") ;;
esac

# Permission mode badge
case "$PERM_MODE" in
    acceptEdits)       PERM_BADGE=$(printf "\033[1;30;48;5;220m edits \033[0m") ;;
    bypassPermissions) PERM_BADGE=$(printf "\033[1;97;41m YOLO \033[0m") ;;
    plan)              PERM_BADGE=$(printf "\033[1;97;44m plan \033[0m") ;;
    default)           PERM_BADGE=$(printf "\033[1;30;47m ask \033[0m") ;;
    *)                 PERM_BADGE=$(printf "\033[2m%s\033[0m" "$PERM_MODE") ;;
esac

# --- Proxy watcher: auto-start if bun + proxy available ---
STATE_FILE="/tmp/claude-proxy-state"
PID_FILE="/tmp/claude-proxy-watcher.pid"
WATCHER="$HOME/.claude/proxy-watcher.ts"
BUN_BIN=$(command -v bun 2>/dev/null)

if [ -n "$BUN_BIN" ] && [ -f "$WATCHER" ]; then
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE" 2>/dev/null)
        if ! kill -0 "$PID" 2>/dev/null; then
            "$BUN_BIN" run "$WATCHER" >/dev/null 2>&1 &
            disown
        fi
    else
        "$BUN_BIN" run "$WATCHER" >/dev/null 2>&1 &
        disown
    fi
fi

# --- Read proxy state (graceful — works without proxy) ---
LIVE_LINE=""
STATS_PART=""
if [ -f "$STATE_FILE" ]; then
    STATE=$(cat "$STATE_FILE" 2>/dev/null)
    if [ -n "$STATE" ] && echo "$STATE" | jq -e '.ts' > /dev/null 2>&1; then
        ACTIVITY=$(echo "$STATE" | jq -r '.activity // "idle"')
        SNIPPET=$(echo "$STATE" | jq -r '.snippet // ""')
        TOOL=$(echo "$STATE" | jq -r '.tool // ""')
        REQS=$(echo "$STATE" | jq -r '.reqs // 0')
        IN_TOK=$(echo "$STATE" | jq -r '.inTok // 0')
        OUT_TOK=$(echo "$STATE" | jq -r '.outTok // 0')
        EXPIRES=$(echo "$STATE" | jq -r '.tokenExp // 0')
        UPDATED=$(echo "$STATE" | jq -r '.ts // 0')

        NOW_MS=$(($(date +%s) * 1000))
        AGE_MS=$((NOW_MS - UPDATED))

        fmt_tok() {
            local n=$1
            if [ "$n" -ge 1000000 ]; then
                printf "%.1fM" "$(echo "$n / 1000000" | bc -l)"
            elif [ "$n" -ge 1000 ]; then
                printf "%.0fK" "$(echo "$n / 1000" | bc -l)"
            else
                printf "%d" "$n"
            fi
        }

        # Token expiry
        KEY=""
        if [ "$EXPIRES" -gt 0 ] 2>/dev/null; then
            MINS=$((EXPIRES / 60))
            if [ "$EXPIRES" -lt 300 ]; then
                KEY=$(printf "\033[1;31m%dm\033[0m" "$MINS")
            elif [ "$EXPIRES" -lt 1800 ]; then
                KEY=$(printf "\033[33m%dm\033[0m" "$MINS")
            else
                KEY=$(printf "\033[32m%dm\033[0m" "$MINS")
            fi
        fi

        # Session cost
        COST_PART=""
        if [ -n "$COST" ] && [ "$COST" != "null" ]; then
            COST_PART=$(printf " \033[2m│\033[0m \033[2m$\033[0m\033[1;33m%s\033[0m" "$COST")
        fi

        # Colorful labeled stats
        STATS_PART=$(printf "\033[2mreq\033[0m \033[1;33m%s\033[0m \033[2m│\033[0m \033[2min\033[0m \033[1;32m%s\033[0m \033[2m│\033[0m \033[2mout\033[0m \033[1;36m%s\033[0m" \
            "$REQS" "$(fmt_tok "$IN_TOK")" "$(fmt_tok "$OUT_TOK")")
        [ -n "$KEY" ] && STATS_PART=$(printf "%s \033[2m│\033[0m \033[2m🔑\033[0m %s" "$STATS_PART" "$KEY")
        STATS_PART="${STATS_PART}${COST_PART}"

        # Live reasoning line
        if [ "$AGE_MS" -lt 60000 ] && [ "$ACTIVITY" != "idle" ]; then
            SNIP=""
            if [ -n "$SNIPPET" ]; then
                SNIP=$(echo "$SNIPPET" | cut -c1-140)
                [ "${#SNIPPET}" -gt 140 ] && SNIP="${SNIP}…"
            fi
            case "$ACTIVITY" in
                thinking)
                    [ -n "$SNIP" ] && LIVE_LINE=$(printf "  \033[1;35mthinking\033[0m \033[2;35m│\033[0m \033[3;35m%s\033[0m" "$SNIP") \
                                   || LIVE_LINE=$(printf "  \033[1;35mthinking\033[0m \033[2;35m…\033[0m") ;;
                tool)
                    [ -n "$SNIP" ] && LIVE_LINE=$(printf "  \033[1;32m%s\033[0m \033[2;32m│\033[0m \033[32m%s\033[0m" "$TOOL" "$SNIP") \
                                   || LIVE_LINE=$(printf "  \033[1;32m%s\033[0m" "$TOOL") ;;
                server_tool)
                    LIVE_LINE=$(printf "  \033[1;33m%s\033[0m \033[2;33m(server)\033[0m" "$TOOL") ;;
                text)
                    [ -n "$SNIP" ] && LIVE_LINE=$(printf "  \033[1;34mresponse\033[0m \033[2;34m│\033[0m \033[34m%s\033[0m" "$SNIP") \
                                   || LIVE_LINE=$(printf "  \033[1;34mresponse\033[0m \033[2;34m…\033[0m") ;;
                starting)    LIVE_LINE=$(printf "  \033[1;33mstarting\033[0m \033[2;33m…\033[0m") ;;
                disconnected) LIVE_LINE=$(printf "  \033[2mproxy disconnected\033[0m") ;;
            esac
        fi
    fi
fi

# === Output ===
# Line 1 (when active): live reasoning / tool activity
# Line 2: [brand] dir git ctx━━━╌╌╌ % [effort] [perms] │ stats

[ -n "$LIVE_LINE" ] && printf "%s\n" "$LIVE_LINE"

if [ -n "$BRAND" ]; then
    printf "%s" "$BRAND"
    [ -n "$DIR_PATH" ] && printf " \033[1;36m%s\033[0m" "$DIR_PATH"
else
    printf "\033[1;36m%s\033[0m" "$DIR_PATH"
fi
printf "%s%s" "$GIT" "$CTX_BAR"
printf " %s %s" "$EFFORT_BADGE" "$PERM_BADGE"
[ -n "$STATS_PART" ] && printf " \033[2m│\033[0m %s" "$STATS_PART"
