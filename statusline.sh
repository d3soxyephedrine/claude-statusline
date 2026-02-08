#!/bin/bash
input=$(cat)

# --- Detect JSON parser once: jq > python3 > node ---
_JP=""
if command -v jq &>/dev/null; then _JP="jq"
elif command -v python3 &>/dev/null; then _JP="py"
elif command -v node &>/dev/null; then _JP="node"
fi

# jget <json> <dotpath> [default] — extract a single value
jget() {
    local json="$1" path="$2" def="${3:-}"
    case "$_JP" in
        jq)   echo "$json" | jq -r "$(echo "$path" | sed 's/\././g; s/^/./' | sed 's/\.\([^.]*\)/.\1/g') // \"$def\"" 2>/dev/null || echo "$def" ;;
        py)   echo "$json" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except: d={}
v=d
for k in '$path'.split('.'):
 v=v.get(k) if isinstance(v,dict) else None
 if v is None: break
print(v if v is not None else '$def')" ;;
        node) echo "$json" | node -e "
let d={};try{d=JSON.parse(require('fs').readFileSync(0,'utf8'))}catch{}
let v=d;for(const k of '$path'.split('.')){v=v?.[k];if(v==null){v=undefined;break}}
console.log(v??'$def')" ;;
        *)    echo "$def" ;;
    esac
}

# jget_multi <json> <"path1 path2 ..."> — extract multiple values, faster (single process)
jget_multi() {
    local json="$1"; shift
    local pairs=("$@")  # "path=VARNAME" pairs
    case "$_JP" in
        jq)
            local script=""
            for pair in "${pairs[@]}"; do
                local path="${pair%%=*}" var="${pair#*=}" def="${pair##*:}"
                [ "$def" = "$pair" ] && def=""
                path="${pair%%=*}"; path="${path%%:*}"
                var="${pair#*=}"; var="${var%%:*}"
                local jqpath=".$(echo "$path" | sed 's/\./\./g')"
                script+="${var}=\$(echo \"\$json\" | jq -r '$jqpath // \"$def\"' 2>/dev/null);"
            done
            eval "$script" ;;
        py)
            local pylines=""
            for pair in "${pairs[@]}"; do
                local pdef="${pair##*:}"; [ "$pdef" = "$pair" ] && pdef=""
                local rest="${pair%:*}"; local path="${rest%%=*}"; local var="${rest#*=}"
                pylines+="
v=d
for k in '$path'.split('.'):
 v=v.get(k) if isinstance(v,dict) else None
 if v is None: break
print(f'$var={v if v is not None else \"$pdef\"}')"
            done
            eval "$(echo "$json" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except: d={}
$pylines")" ;;
        node)
            local nodelines=""
            for pair in "${pairs[@]}"; do
                local pdef="${pair##*:}"; [ "$pdef" = "$pair" ] && pdef=""
                local rest="${pair%:*}"; local path="${rest%%=*}"; local var="${rest#*=}"
                nodelines+="v=d;for(const k of '$path'.split('.')){v=v?.[k];if(v==null){v=undefined;break}};console.log('$var='+(v??'$pdef'));"
            done
            eval "$(echo "$json" | node -e "
const fs=require('fs');let d={};try{d=JSON.parse(fs.readFileSync(0,'utf8'))}catch{};let v;
$nodelines")" ;;
    esac
}

# Extract all input fields in one call
jget_multi "$input" \
    "workspace.current_dir=CURRENT_DIR:~" \
    "context_window.used_percentage=CONTEXT_USED:" \
    "cost.total_cost_usd=COST:"

# Permission mode from settings.json
PERM_MODE="default"
if [ -f "$HOME/.claude/settings.json" ]; then
    PERM_MODE=$(jget "$(cat "$HOME/.claude/settings.json")" "permissions.defaultMode" "default")
fi
[ -z "$PERM_MODE" ] && PERM_MODE="default"

# Effort level (env var — not in statusline input)
EFFORT="${CLAUDE_CODE_EFFORT_LEVEL:-high}"

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
    STATE_JSON=$(cat "$STATE_FILE" 2>/dev/null)
    if [ -n "$STATE_JSON" ]; then
        jget_multi "$STATE_JSON" \
            "activity=ACTIVITY:idle" \
            "reqs=REQS:0" \
            "inTok=IN_TOK:0" \
            "outTok=OUT_TOK:0" \
            "tokenExp=EXPIRES:0" \
            "ts=UPDATED:0"
        SNIPPET=$(jget "$STATE_JSON" "snippet" "")
        TOOL=$(jget "$STATE_JSON" "tool" "")

        NOW_MS=$(($(date +%s) * 1000))
        AGE_MS=$((NOW_MS - ${UPDATED:-0}))

        fmt_tok() {
            local n=$1
            if [ "$n" -ge 1000000 ] 2>/dev/null; then
                printf "%.1fM" "$(echo "$n / 1000000" | bc -l 2>/dev/null || python3 -c "print($n/1000000)")"
            elif [ "$n" -ge 1000 ] 2>/dev/null; then
                printf "%.0fK" "$(echo "$n / 1000" | bc -l 2>/dev/null || python3 -c "print($n/1000)")"
            else
                printf "%d" "$n"
            fi
        }

        # Token expiry
        KEY=""
        if [ "${EXPIRES:-0}" -gt 0 ] 2>/dev/null; then
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
            "${REQS:-0}" "$(fmt_tok "${IN_TOK:-0}")" "$(fmt_tok "${OUT_TOK:-0}")")
        [ -n "$KEY" ] && STATS_PART=$(printf "%s \033[2m│\033[0m \033[2m🔑\033[0m %s" "$STATS_PART" "$KEY")
        STATS_PART="${STATS_PART}${COST_PART}"

        # Live reasoning line
        if [ "${AGE_MS:-999999}" -lt 60000 ] && [ "${ACTIVITY:-idle}" != "idle" ]; then
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
