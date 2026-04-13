#!/bin/bash
input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'
RED='\033[31m'; BLUE='\033[34m'; RESET='\033[0m'; BOLD='\033[1m'

if [ "$PCT" -ge 85 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 60 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT * 10 / 100)); EMPTY=$((10 - FILLED)); BAR=""
[ "$FILLED" -gt 0 ] && printf -v FILL "%${FILLED}s" && BAR="${FILL// /█}"
[ "$EMPTY"  -gt 0 ] && printf -v PAD  "%${EMPTY}s"  && BAR="${BAR}${PAD// /░}"

COST_FMT=$(printf '$%.3f' "$COST")
MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))

SESSION_ID=$(echo "$input" | jq -r '.session_id')
CACHE_FILE="/tmp/cc-statusline-$SESSION_ID"
CACHE_AGE=0
[ -f "$CACHE_FILE" ] && CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)))

if [ ! -f "$CACHE_FILE" ] || [ "$CACHE_AGE" -gt 5 ]; then
    if git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
        BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
        STAGED=$(git -C "$DIR" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
        MODIFIED=$(git -C "$DIR" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
        echo "$BRANCH|$STAGED|$MODIFIED" > "$CACHE_FILE"
    else
        echo "||" > "$CACHE_FILE"
    fi
fi
IFS='|' read -r BRANCH STAGED MODIFIED < "$CACHE_FILE"

FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
RL_SEGMENT=""
[ -n "$FIVE_H" ] && RL_SEGMENT=" | ${YELLOW}5h: $(printf '%.0f' "$FIVE_H")%${RESET}"

GIT_SEGMENT=""
if [ -n "$BRANCH" ]; then
    CHANGES=""
    [ "$STAGED"   -gt 0 ] && CHANGES="${GREEN}+${STAGED}${RESET}"
    [ "$MODIFIED" -gt 0 ] && CHANGES="${CHANGES} ${YELLOW}~${MODIFIED}${RESET}"
    GIT_SEGMENT=" | 🌿 ${BOLD}${BRANCH}${RESET}${CHANGES:+ $CHANGES}"
fi

echo -e "${CYAN}${BOLD}${MODEL}${RESET} | 📁 ${DIR##*/}${GIT_SEGMENT} | ${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${BLUE}${COST_FMT}${RESET} | ⏱ ${MINS}m${SECS}s${RL_SEGMENT}"