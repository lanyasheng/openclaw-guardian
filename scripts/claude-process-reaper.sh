#!/bin/bash
# Claude Code Process Reaper — kills leaked Claude CLI sessions
#
# Problem: Claude Code instances launched interactively or as subagents
# sometimes survive indefinitely after sessions end (terminal closed,
# subagent done, etc.). Over days this accumulates dozens of zombie
# processes eating RAM and CPU.
#
# Solution: Periodically kill claude processes older than MAX_AGE.
# This is safe because interactive sessions rarely exceed a few hours,
# and any legitimate long-running work should be done via cron/triggers.
#
# Install in crontab:
#   */30 * * * * /bin/bash ~/.openclaw/scripts/claude-process-reaper.sh
#
# Dry-run:
#   bash ~/.openclaw/scripts/claude-process-reaper.sh --dry-run

set -uo pipefail

# --- Config ---
MAX_AGE_HOURS=${CLAUDE_REAPER_MAX_AGE_HOURS:-12}  # Kill processes older than this
MAX_AGE_SECS=$((MAX_AGE_HOURS * 3600))
LOG="${HOME}/.openclaw/logs/claude-reaper.log"
MAX_LOG_SIZE=524288  # 512KB
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# --- Helpers ---
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "$(timestamp) $1" >> "$LOG"; }

rotate_log() {
    if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG" "${LOG}.old"
    fi
}

mkdir -p "$(dirname "$LOG")"
rotate_log

NOW_EPOCH=$(date +%s)
KILLED=0
SKIPPED=0
TOTAL=0

# --- Find and evaluate all claude processes ---
# Match: "claude" as standalone command (not grep, not server.cjs, not plugins)
while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $1}')
    [ -z "$pid" ] && continue

    TOTAL=$((TOTAL + 1))

    # Get process start time
    start_str=$(ps -o lstart= -p "$pid" 2>/dev/null) || continue
    start_epoch=$(date -j -f "%c" "$start_str" +%s 2>/dev/null) || {
        # Fallback: try alternate format (Linux)
        start_epoch=$(date -d "$start_str" +%s 2>/dev/null) || continue
    }

    age_secs=$((NOW_EPOCH - start_epoch))
    age_hours=$((age_secs / 3600))
    tty_info=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')

    if [ "$age_secs" -gt "$MAX_AGE_SECS" ]; then
        if $DRY_RUN; then
            echo "[DRY-RUN] WOULD KILL: pid=$pid tty=$tty_info age=${age_hours}h"
            log "[DRY-RUN] Would kill pid=$pid tty=$tty_info age=${age_hours}h"
        else
            # Kill child processes first (server.cjs, MCP plugins, etc.)
            pkill -TERM -P "$pid" 2>/dev/null
            kill -TERM "$pid" 2>/dev/null

            KILLED=$((KILLED + 1))
            log "[REAP] Killed claude pid=$pid tty=$tty_info age=${age_hours}h"
        fi
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done < <(ps -eo pid,command | grep -E "^\s*[0-9]+\s+claude\s" | grep -v grep)

# --- Force-kill survivors (SIGTERM might not work on stuck processes) ---
if [ "$KILLED" -gt 0 ] && ! $DRY_RUN; then
    sleep 3
    FORCE_KILLED=0
    while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        [ -z "$pid" ] && continue
        start_str=$(ps -o lstart= -p "$pid" 2>/dev/null) || continue
        start_epoch=$(date -j -f "%c" "$start_str" +%s 2>/dev/null || date -d "$start_str" +%s 2>/dev/null) || continue
        age_secs=$((NOW_EPOCH - start_epoch))
        if [ "$age_secs" -gt "$MAX_AGE_SECS" ]; then
            kill -9 "$pid" 2>/dev/null && FORCE_KILLED=$((FORCE_KILLED + 1))
        fi
    done < <(ps -eo pid,command | grep -E "^\s*[0-9]+\s+claude\s" | grep -v grep)
    [ "$FORCE_KILLED" -gt 0 ] && log "[REAP] Force-killed $FORCE_KILLED survivors with SIGKILL"
fi

# --- Summary ---
if [ "$KILLED" -gt 0 ] || $DRY_RUN; then
    log "[SUMMARY] total=$TOTAL killed=$KILLED skipped=$SKIPPED max_age=${MAX_AGE_HOURS}h"
fi

# --- Memory stats (log if claude processes use >2GB total) ---
TOTAL_RSS=$(ps -eo rss,command | grep -E "^\s*[0-9]+\s+claude\s" | grep -v grep | awk '{sum+=$1} END {print sum+0}')
TOTAL_RSS_MB=$((TOTAL_RSS / 1024))
if [ "$TOTAL_RSS_MB" -gt 2048 ]; then
    log "[MEMORY-WARN] Claude processes using ${TOTAL_RSS_MB}MB total RSS"
fi

$DRY_RUN && echo "[DRY-RUN] Summary: total=$TOTAL would_kill=$KILLED safe=$SKIPPED"
