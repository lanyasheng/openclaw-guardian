#!/bin/bash
# OpenClaw 心跳守护脚本 v2.1 - 健康检查 + 配置备份 + 自愈
# 参考: openclaw-self-healing watchdog v4.2
# 改进: HTTP 健康检查 / doctor --fix / 指数退避 / last-known-good 回滚 / 活跃时段 DEGRADED 收敛
# 触发: cron 每5分钟（推荐）
# 用法: bash ~/.openclaw/scripts/heartbeat-guardian.sh [--dry-run]

export PATH=/Users/study/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH

# ============================================================================
# 配置
# ============================================================================
OPENCLAW_DIR="/Users/study/.openclaw"
BACKUP_DIR="$OPENCLAW_DIR/backups/auto"
LAST_KNOWN_GOOD_DIR="$OPENCLAW_DIR/backups/last-known-good"
CONFIG_FILE="$OPENCLAW_DIR/openclaw.json"
CRON_FILE="$OPENCLAW_DIR/cron/jobs.json"
LOG_FILE="$OPENCLAW_DIR/logs/guardian.log"
LOG_DIR="$OPENCLAW_DIR/logs"
ERR_LOG="$OPENCLAW_DIR/logs/gateway.err.log"
PYTHON=/opt/homebrew/bin/python3.12
STATE_DIR="$OPENCLAW_DIR/watchdog"
LAUNCHD_SERVICE="ai.openclaw.gateway"

GATEWAY_PORT=18789
HEALTH_TIMEOUT=5
RPC_HEALTH_TIMEOUT=8
CLI_HEALTH_TIMEOUT=12
DEGRADED_LOG_WINDOW_SECONDS=180
DEGRADED_ERROR_THRESHOLD=15
DEGRADED_CONSECUTIVE_THRESHOLD=3
MAX_BACKUPS=24
MAX_TOTAL_RETRIES=6
CRASH_DECAY_HOURS=6
MAX_DOCTOR_FIX=2

# claude 进程数熔断阈值
MAX_CLAUDE_PROCESSES=${OPENCLAW_MAX_CONCURRENT_SUBAGENTS:-15}
CLAUDE_PROCESS_WARN_THRESHOLD=$((MAX_CLAUDE_PROCESSES / 2))

# 指数退避延迟（秒）
BACKOFF_DELAYS=(60 120 300 600 900 1800)

# ============================================================================
# 活跃时段配置（用于收敛 DEGRADED 白天重启）
# ============================================================================
# 时区设置（macOS date 命令使用 TZ 环境变量）
ACTIVE_HOURS_TZ="Asia/Shanghai"
# 活跃时段起始时间（24小时制，小时:分钟）
ACTIVE_HOURS_START="08:00"
# 活跃时段结束时间（24小时制，小时:分钟）
# 注意：结束时间是包含的，即 23:00 表示直到 23:59:59 都算活跃时段
ACTIVE_HOURS_END="23:00"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# dry-run 模式
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

mkdir -p "$BACKUP_DIR" "$LAST_KNOWN_GOOD_DIR" "$STATE_DIR" "$OPENCLAW_DIR/logs"

# ============================================================================
# 状态文件
# ============================================================================
CRASH_COUNTER_FILE="$STATE_DIR/crash-counter"
CRASH_TIMESTAMP_FILE="$STATE_DIR/crash-timestamp"
COOLDOWN_FILE="$STATE_DIR/last-restart"
DOCTOR_FIX_COUNTER_FILE="$STATE_DIR/doctor-fix-attempts"
UNHEALTHY_STREAK_FILE="$STATE_DIR/unhealthy-streak"
UNHEALTHY_REASON_FILE="$STATE_DIR/unhealthy-reason"
HEALING_LOCK="/tmp/openclaw-guardian.lock"

# ============================================================================
# 工具函数
# ============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    if $DRY_RUN; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
    fi
}

# ============================================================================
# 活跃时段检测（Asia/Shanghai 时区）
# 返回 0 表示在活跃时段内，1 表示在活跃时段外
# ============================================================================
is_in_active_hours() {
    # 获取 Asia/Shanghai 时区的当前时间（HH:MM 格式）
    local current_time
    current_time=$(TZ="$ACTIVE_HOURS_TZ" date +%H:%M)

    # 解析配置的起止时间（转换为分钟）
    local start_hour=${ACTIVE_HOURS_START%%:*}
    local start_min=${ACTIVE_HOURS_START##*:}
    local end_hour=${ACTIVE_HOURS_END%%:*}
    local end_min=${ACTIVE_HOURS_END##*:}

    local start_total=$((10#$start_hour * 60 + 10#$start_min))
    local end_total=$((10#$end_hour * 60 + 10#$end_min))

    # 解析当前时间
    local curr_hour=${current_time%%:*}
    local curr_min=${current_time##*:}
    local curr_total=$((10#$curr_hour * 60 + 10#$curr_min))

    # 判断是否在活跃时段内（包含边界）
    if [[ $curr_total -ge $start_total && $curr_total -le $end_total ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# 判断是否应该因 DEGRADED 触发重启
# 活跃时段内 DEGRADED 只 warn，不 restart
# 硬故障（HTTP/RPC/PID/config）不受活跃时段限制，始终 restart
# ============================================================================
should_restart_for_degraded() {
    local reason="$1"

    # 如果不是 DEGRADED 原因，直接允许 restart
    if [[ "$reason" != DEGRADED:* ]]; then
        return 0
    fi

    # DEGRADED 情况下，检查是否在活跃时段
    if is_in_active_hours; then
        return 1  # 在活跃时段内，不允许 restart
    else
        return 0  # 在活跃时段外，允许 restart
    fi
}

# ============================================================================
# Healing 锁（防止并发执行）
# ============================================================================
acquire_healing_lock() {
    if mkdir "$HEALING_LOCK" 2>/dev/null; then
        trap "rmdir '$HEALING_LOCK' 2>/dev/null || true" EXIT
        return 0
    fi
    # stale lock 检测（超过 10 分钟强制释放）
    local lock_age=$(( $(date +%s) - $(stat -f %m "$HEALING_LOCK" 2>/dev/null || echo "0") ))
    if [[ $lock_age -gt 600 ]]; then
        rmdir "$HEALING_LOCK" 2>/dev/null || true
        if mkdir "$HEALING_LOCK" 2>/dev/null; then
            trap "rmdir '$HEALING_LOCK' 2>/dev/null || true" EXIT
            return 0
        fi
    fi
    return 1
}

# ============================================================================
# Crash 计数器（含自动衰减）
# ============================================================================
get_crash_count() {
    if [[ -f "$CRASH_COUNTER_FILE" ]]; then
        cat "$CRASH_COUNTER_FILE"
    else
        echo "0"
    fi
}

check_crash_decay() {
    if [[ ! -f "$CRASH_TIMESTAMP_FILE" ]]; then
        return
    fi
    local last_crash=$(cat "$CRASH_TIMESTAMP_FILE")
    local now=$(date +%s)
    local elapsed=$((now - last_crash))
    local decay_seconds=$((CRASH_DECAY_HOURS * 3600))
    if [[ $elapsed -ge $decay_seconds ]]; then
        log "[INFO] Crash counter auto-reset (${CRASH_DECAY_HOURS}h elapsed)"
        if $DRY_RUN; then
            log "[DRY-RUN] Would reset crash counter"
            return
        fi
        echo "0" > "$CRASH_COUNTER_FILE"
        rm -f "$CRASH_TIMESTAMP_FILE"
    fi
}

increment_crash_count() {
    if $DRY_RUN; then
        return
    fi
    local count=$(get_crash_count)
    echo $((count + 1)) > "$CRASH_COUNTER_FILE"
    date +%s > "$CRASH_TIMESTAMP_FILE"
}

decrement_crash_count() {
    if $DRY_RUN; then
        return
    fi
    local count=$(get_crash_count)
    if [[ $count -gt 0 ]]; then
        echo $((count - 1)) > "$CRASH_COUNTER_FILE"
    fi
}

reset_crash_count() {
    if $DRY_RUN; then
        return
    fi
    echo "0" > "$CRASH_COUNTER_FILE"
    rm -f "$CRASH_TIMESTAMP_FILE"
}

# ============================================================================
# 指数退避
# ============================================================================
get_backoff_delay() {
    local crash_count=$(get_crash_count)
    local index=$((crash_count - 1))
    if [[ $index -lt 0 ]]; then
        index=0
    elif [[ $index -ge ${#BACKOFF_DELAYS[@]} ]]; then
        index=$((${#BACKOFF_DELAYS[@]} - 1))
    fi
    echo "${BACKOFF_DELAYS[$index]}"
}

is_in_cooldown() {
    if [[ ! -f "$COOLDOWN_FILE" ]]; then
        return 1
    fi
    local last_restart=$(cat "$COOLDOWN_FILE")
    local now=$(date +%s)
    local elapsed=$((now - last_restart))
    local required_cooldown=$(get_backoff_delay)
    if [[ $elapsed -lt $required_cooldown ]]; then
        local remaining=$((required_cooldown - elapsed))
        log "[INFO] Backoff cooldown: ${remaining}s remaining (need ${required_cooldown}s)"
        return 0
    fi
    return 1
}

set_last_restart() {
    if $DRY_RUN; then
        return
    fi
    date +%s > "$COOLDOWN_FILE"
}

# ============================================================================
# 连续异常计数（用于退化态判定）
# ============================================================================
get_unhealthy_streak() {
    if [[ -f "$UNHEALTHY_STREAK_FILE" ]]; then
        cat "$UNHEALTHY_STREAK_FILE"
    else
        echo "0"
    fi
}

reset_unhealthy_streak() {
    if $DRY_RUN; then
        return
    fi
    echo "0" > "$UNHEALTHY_STREAK_FILE"
    rm -f "$UNHEALTHY_REASON_FILE"
}

increment_unhealthy_streak() {
    local reason="$1"
    local count=$(get_unhealthy_streak)
    count=$((count + 1))
    if $DRY_RUN; then
        echo "$count"
        return
    fi
    echo "$count" > "$UNHEALTHY_STREAK_FILE"
    echo "$reason" > "$UNHEALTHY_REASON_FILE"
    echo "$count"
}

# ============================================================================
# HTTP 健康检查（核心改进 #1）
# ============================================================================
check_http_health() {
    local url="http://127.0.0.1:$GATEWAY_PORT/health"
    local response
    if response=$(curl -s -o /dev/null -w "%{http_code}" --max-time $HEALTH_TIMEOUT "$url" 2>/dev/null); then
        if [[ "$response" == "200" ]]; then
            echo "OK"
        else
            echo "HTTP_$response"
        fi
    else
        echo "UNREACHABLE"
    fi
}

# ============================================================================
# RPC 健康检查（避免 HTTP=200 但业务层失效）
# ============================================================================
check_rpc_health() {
    # Use HTTP /health endpoint instead of `openclaw health` CLI
    # to avoid SOCKS proxy interference (V2rayU on Wi-Fi, port 1080)
    local response
    response=$(curl -m "$RPC_HEALTH_TIMEOUT" -s "http://127.0.0.1:${GATEWAY_PORT}/health" 2>/dev/null)
    if echo "$response" | grep -q '"ok":true'; then
        echo "OK"
    elif [[ -z "$response" ]]; then
        echo "TIMEOUT"
    else
        echo "FAILED"
    fi
}

# ============================================================================
# 退化信号检测（日志层）
# ============================================================================
check_degraded_signals() {
    local cli_degraded
    if [[ ! -f "$ERR_LOG" ]]; then
        cli_degraded=$(check_cli_degraded_signals)
        echo "$cli_degraded"
        return
    fi

    local now=$(date +%s)
    local mtime=$(stat -f %m "$ERR_LOG" 2>/dev/null || echo "0")
    local age=$((now - mtime))
    if [[ "$age" -gt "$DEGRADED_LOG_WINDOW_SECONDS" ]]; then
        cli_degraded=$(check_cli_degraded_signals)
        echo "$cli_degraded"
        return
    fi

    local sample
    sample=$(tail -200 "$ERR_LOG" 2>/dev/null || true)
    local severe
    severe=$(printf "%s\n" "$sample" | grep -E "embedded run timeout|FailoverError: LLM request timed out|gateway closed \(1006|abnormal closure" | wc -l | tr -d ' ')
    if [[ "$severe" -ge "$DEGRADED_ERROR_THRESHOLD" ]]; then
        echo "DEGRADED:$severe"
    else
        cli_degraded=$(check_cli_degraded_signals)
        echo "$cli_degraded"
    fi
}

check_cli_degraded_signals() {
    "$PYTHON" - "$CLI_HEALTH_TIMEOUT" <<'PY' 2>/dev/null
import re
import subprocess
import sys

timeout = int(sys.argv[1])
try:
    proc = subprocess.run(
        ["openclaw", "health"],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
except subprocess.TimeoutExpired:
    print("DEGRADED:cli_health_timeout")
    raise SystemExit(0)

output = (proc.stdout or "") + "\n" + (proc.stderr or "")
if proc.returncode != 0:
    lowered = output.lower()
    if "gateway timeout" in lowered or "gatewaytransporterror" in lowered:
        print("DEGRADED:cli_health_timeout")
    else:
        print("DEGRADED:cli_health_failed")
    raise SystemExit(0)

match = re.search(r"Gateway event loop:\s+degraded\s+([^\n]+)", output)
if not match:
    print("NONE")
    raise SystemExit(0)

detail = match.group(1).strip()
reasons = re.search(r"reasons=([A-Za-z0-9_,.-]+)", detail)
reason_text = reasons.group(1) if reasons else "unknown"
print(f"DEGRADED:cli_event_loop:{reason_text}")
PY
}

# ============================================================================
# PID 状态检查（参考 watchdog）
# ============================================================================
check_pid_status() {
    local status=$(launchctl list 2>/dev/null | grep "$LAUNCHD_SERVICE" || echo "")
    if [[ -z "$status" ]]; then
        echo "NOT_LOADED"
        return
    fi
    local pid=$(echo "$status" | awk '{print $1}')
    local exit_code=$(echo "$status" | awk '{print $2}')
    if [[ "$pid" != "-" ]] && [[ "$pid" -gt 0 ]] 2>/dev/null; then
        echo "PID:$pid"
    elif [[ "$exit_code" -lt 0 ]] 2>/dev/null; then
        echo "CRASHED:signal_$exit_code"
    else
        echo "STOPPED:exit_$exit_code"
    fi
}

get_launchd_pid() {
    local status
    status=$(launchctl list 2>/dev/null | grep "$LAUNCHD_SERVICE" || echo "")
    if [[ -z "$status" ]]; then
        echo ""
        return
    fi
    local pid
    pid=$(echo "$status" | awk '{print $1}')
    if [[ "$pid" != "-" ]] && [[ "$pid" -gt 0 ]] 2>/dev/null; then
        echo "$pid"
    else
        echo ""
    fi
}

get_port_owner_pid() {
    lsof -ti "tcp:$GATEWAY_PORT" -sTCP:LISTEN 2>/dev/null | head -1
}

reconcile_gateway_ownership() {
    local launchd_pid
    launchd_pid=$(get_launchd_pid)
    local port_pid
    port_pid=$(get_port_owner_pid)

    if [[ -n "$port_pid" ]] && [[ "$port_pid" != "$launchd_pid" ]]; then
        log "[WARN] Stray gateway owner detected on port $GATEWAY_PORT: pid=$port_pid (launchd_pid=${launchd_pid:-none})"
        if ! $DRY_RUN; then
            kill -TERM "$port_pid" 2>/dev/null || true
            sleep 2
            if kill -0 "$port_pid" 2>/dev/null; then
                kill -KILL "$port_pid" 2>/dev/null || true
            fi
        fi
    fi
}

# ============================================================================
# Config 错误检测（参考 watchdog v4.2）
# ============================================================================
is_config_error() {
    if [[ ! -f "$ERR_LOG" ]]; then
        return 1
    fi
    tail -50 "$ERR_LOG" 2>/dev/null | grep -qi "config invalid\|unrecognized key\|doctor --fix\|invalid config\|schema\|validation failed" 2>/dev/null
}

# ============================================================================
# openclaw doctor --fix 自动修复（核心改进 #2，不用 Claude）
# ============================================================================
try_doctor_fix() {
    local fix_count=0
    if [[ -f "$DOCTOR_FIX_COUNTER_FILE" ]]; then
        fix_count=$(cat "$DOCTOR_FIX_COUNTER_FILE")
    fi

    if [[ $fix_count -ge $MAX_DOCTOR_FIX ]]; then
        log "[WARN] doctor --fix already tried ${fix_count} times, skipping (manual intervention needed)"
        return 1
    fi

    if service_version_drift; then
        log "[WARN] Refusing doctor --fix until Gateway service version matches CLI"
        repair_gateway_service_install || return 1
        if service_version_drift; then
            log "[ERROR] Gateway service version still mismatched after repair attempt; skipping doctor --fix"
            return 1
        fi
    fi

    log "[ACTION] Config error detected — running 'openclaw doctor --fix --non-interactive --yes' (attempt $((fix_count+1))/${MAX_DOCTOR_FIX})"

    if $DRY_RUN; then
        log "[DRY-RUN] Would run: openclaw doctor --fix --non-interactive --yes"
        return 0
    fi

    echo $((fix_count + 1)) > "$DOCTOR_FIX_COUNTER_FILE"

    local before_doctor="$CONFIG_FILE.pre-doctor.$TIMESTAMP"
    cp "$CONFIG_FILE" "$before_doctor"

    local doctor_output
    doctor_output=$(openclaw doctor --fix --non-interactive --yes 2>&1) || true
    log "[INFO] doctor --fix output: ${doctor_output:0:300}"

    if validate_current_config_schema; then
        log "[OK] doctor --fix result passed schema validation"
        return 0
    fi

    cp "$CONFIG_FILE" "$CONFIG_FILE.bad-doctor.$TIMESTAMP"
    cp "$before_doctor" "$CONFIG_FILE"
    log "[ERROR] doctor --fix produced unsafe config; restored pre-doctor backup"
    return 1
}

reset_doctor_fix_counter() {
    if $DRY_RUN; then
        return
    fi
    rm -f "$DOCTOR_FIX_COUNTER_FILE"
}
# ============================================================================
# 等待 Gateway 启动（循环检查 HTTP，最多 30s）
# ============================================================================
wait_for_gateway_startup() {
    local reason="$1"
    if $DRY_RUN; then
        log "[DRY-RUN] Would wait for Gateway startup after $reason"
        return 0
    fi
    local wait_max=30
    local wait_interval=5
    local waited=0
    local http_result=""
    while [[ $waited -lt $wait_max ]]; do
        sleep $wait_interval
        waited=$(($waited + $wait_interval))
        http_result=$(check_http_health)
        if [[ "$http_result" == "OK" ]]; then
            log "[RECOVERED] Gateway recovered after $reason (waited ${waited}s)"
            return 0
        fi
        log "[INFO] Waiting for Gateway startup after $reason... ${waited}s/${wait_max}s (HTTP=$http_result)"
    done
    log "[WARN] Gateway still unhealthy after ${wait_max}s post $reason (HTTP=$http_result)"
    return 1
}

run_post_update() {
    if $DRY_RUN; then
        log "[DRY-RUN] Would run post-update.sh"
        return 0
    fi
    bash "$OPENCLAW_DIR/scripts/post-update.sh" >> "$LOG_FILE" 2>&1 || true
}


# ============================================================================
# Last-Known-Good 配置管理（核心改进 #3）
# ============================================================================
save_last_known_good() {
    if ! config_file_is_safe "$CONFIG_FILE"; then
        log "[WARN] Refusing to save last-known-good: config is not schema-safe"
        return 1
    fi
    if $DRY_RUN; then
        log "[DRY-RUN] Would save last-known-good config"
        return 0
    fi
    cp "$CONFIG_FILE" "$LAST_KNOWN_GOOD_DIR/openclaw.json"
    log "[BACKUP] Saved last-known-good config"
}

restore_last_known_good() {
    local lkg_file="$LAST_KNOWN_GOOD_DIR/openclaw.json"
    if [[ -f "$lkg_file" ]] && config_file_is_safe "$lkg_file"; then
        if $DRY_RUN; then
            log "[DRY-RUN] Would restore last-known-good config"
            return 0
        fi
        cp "$CONFIG_FILE" "$CONFIG_FILE.bad.$TIMESTAMP"
        cp "$lkg_file" "$CONFIG_FILE"
        log "[RECOVERED] Restored last-known-good config (bad config saved as .bad.$TIMESTAMP)"
        return 0
    fi
    return 1
}

config_file_is_safe() {
    local file="$1"
    "$PYTHON" - "$file" <<'PY' 2>/dev/null
import json
import os
import plistlib
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

plist_path = os.path.expanduser("~/Library/LaunchAgents/ai.openclaw.gateway.plist")
legacy_gateway = False
try:
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)
    args = " ".join(plist.get("ProgramArguments", []))
    legacy_gateway = "openclawbugfix/openclaw" in args or "2026.4" in plist.get("Comment", "")
except Exception:
    legacy_gateway = False

problems = []
thread_bindings = (
    data.get("channels", {})
    .get("discord", {})
    .get("threadBindings", {})
)
if "spawnSessions" in thread_bindings:
    problems.append("channels.discord.threadBindings.spawnSessions")

qmd_update = (
    data.get("memory", {})
    .get("qmd", {})
    .get("update", {})
)
for key in ("startup", "startupDelayMs"):
    if key in qmd_update:
        problems.append(f"memory.qmd.update.{key}")

if legacy_gateway and problems:
    print(", ".join(problems))
    sys.exit(1)
PY
}

validate_current_config_schema() {
    config_file_is_safe "$CONFIG_FILE" && openclaw config validate >/tmp/openclaw-config-validate.out 2>&1
}

get_cli_version() {
    openclaw --version 2>/dev/null | awk '{print $2}' | head -1
}

get_service_index_path() {
    "$PYTHON" - <<'PY' 2>/dev/null
import os
import plistlib

plist_path = os.path.expanduser("~/Library/LaunchAgents/ai.openclaw.gateway.plist")
with open(plist_path, "rb") as f:
    plist = plistlib.load(f)
for arg in plist.get("ProgramArguments", []):
    if arg.endswith("/dist/index.js") or arg.endswith("/openclaw/dist/index.js"):
        print(arg)
        break
PY
}

get_package_version_for_index() {
    local index_path="$1"
    "$PYTHON" - "$index_path" <<'PY' 2>/dev/null
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).resolve()
for parent in [path.parent, *path.parents]:
    package = parent / "package.json"
    if package.exists():
        with package.open(encoding="utf-8") as f:
            print(json.load(f).get("version", ""))
        break
PY
}

get_service_version() {
    local index_path
    index_path=$(get_service_index_path)
    if [[ -z "$index_path" ]]; then
        echo ""
        return
    fi
    get_package_version_for_index "$index_path"
}

service_version_drift() {
    local cli_version service_version service_index
    cli_version=$(get_cli_version)
    service_version=$(get_service_version)
    service_index=$(get_service_index_path)

    if [[ -z "$cli_version" ]] || [[ -z "$service_version" ]]; then
        log "[WARN] Unable to compare OpenClaw CLI/Gateway versions (cli=${cli_version:-unknown}, service=${service_version:-unknown})"
        return 1
    fi

    if [[ "$cli_version" != "$service_version" ]]; then
        log "[ERROR] OpenClaw CLI/Gateway version drift: cli=$cli_version service=$service_version index=${service_index:-unknown}"
        return 0
    fi
    return 1
}

repair_gateway_service_install() {
    log "[ACTION] Reinstalling Gateway LaunchAgent from current OpenClaw CLI"
    if $DRY_RUN; then
        log "[DRY-RUN] Would run: openclaw gateway install --force --port $GATEWAY_PORT"
        return 0
    fi

    local output
    output=$(openclaw gateway install --force --port "$GATEWAY_PORT" 2>&1) || {
        log "[WARN] gateway install --force failed: ${output:0:500}"
        return 1
    }
    log "[INFO] gateway install --force output: ${output:0:500}"
    return 0
}

find_safe_config_backup() {
    local candidate
    for candidate in $(ls -1t "$BACKUP_DIR"/openclaw.json.* 2>/dev/null); do
        if config_file_is_safe "$candidate"; then
            echo "$candidate"
            return 0
        fi
        log "[WARN] Skipping unsafe config backup: $candidate"
    done
    return 1
}

# ============================================================================
# 改进的重启（参考 watchdog: kickstart -k + 降级 start）
# ============================================================================
# 系统资源保护（P0 — 防止 OOM 导致系统不可用）
# ============================================================================
check_system_resources() {
    local load_1min=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' | cut -d. -f1)
    local cpu_count=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
    local load_threshold=$((cpu_count * 3))

    if [[ -n "$load_1min" ]] && [[ "$load_1min" -gt "$load_threshold" ]]; then
        log "[EMERGENCY] System load $load_1min exceeds threshold $load_threshold (CPUs=$cpu_count)"
        log "[EMERGENCY] Killing all openclaw processes to protect system"
        killall -9 openclaw-gateway 2>/dev/null || true
        killall -9 openclaw 2>/dev/null || true
        log "[EMERGENCY] Processes killed, skipping restart to let system recover"
        return 1
    fi
    return 0
}

# ============================================================================
request_restart() {
    local reason="$1"
    local plist="$HOME/Library/LaunchAgents/$LAUNCHD_SERVICE.plist"
    local launchd_domain="gui/$(id -u)"

    if $DRY_RUN; then
        log "[DRY-RUN] Would restart: $reason"
        return 0
    fi

    log "[ACTION] Restart requested: $reason"

    # P0: Check system resources before attempting restart
    if ! check_system_resources; then
        log "[SKIP-RESTART] System overloaded, restart aborted to prevent OOM cascade"
        return 1
    fi

    reconcile_gateway_ownership

    # 服务未加载时先 bootstrap，避免 start/kickstart 无效
    if ! launchctl print "$launchd_domain/$LAUNCHD_SERVICE" >/dev/null 2>&1; then
        if [[ -f "$plist" ]]; then
            launchctl bootstrap "$launchd_domain" "$plist" 2>/dev/null || true
            log "[INFO] LaunchAgent bootstrap attempted"
        else
            log "[WARN] LaunchAgent plist missing: $plist"
        fi
    fi

    # 先尝试 kickstart -k（强制重启），失败则降级到 start
    launchctl kickstart -k "$launchd_domain/$LAUNCHD_SERVICE" 2>/dev/null || \
        launchctl kickstart "$launchd_domain/$LAUNCHD_SERVICE" 2>/dev/null || \
        launchctl start "$LAUNCHD_SERVICE" 2>/dev/null || true

    set_last_restart
    log "[ACTION] Restart command issued"
}

# ============================================================================
# 主逻辑
# ============================================================================
log "=== Guardian v2 heartbeat start ==="
if $DRY_RUN; then
    log "[INFO] *** DRY-RUN MODE ***"
fi

# 并发锁
if ! acquire_healing_lock; then
    log "[INFO] Another guardian instance running, skipping"
    exit 0
fi

# crash 计数器衰减
check_crash_decay

ERRORS=0
RECOVERED=0

# ─── Step 0: P0 系统保护（每次心跳都执行，不受 backoff 影响） ───
# Fix: backoff 期间跳过保护导致 OOM 系统崩溃 (2026-03-13 incident)
# Fix: 孤儿检测排除 PPID=1 导致真正的孤儿进程漏网
# Fix: 清理频率从 24h 改为每 5min 心跳
{
    # 0a: 孤儿进程清理 (PPID=1 的 openclaw = 父进程已死的孤儿)
    GWPID=$(pgrep -f "openclaw-gateway" 2>/dev/null | head -1)
    if [[ -n "$GWPID" ]]; then
        # Exclude gateway and its known parent wrapper from orphan kill
        GW_PARENT=$(ps -o ppid= -p "$GWPID" 2>/dev/null | tr -d ' ')
        ORPHAN_PIDS=""
        for _pid in $(ps -eo pid,ppid,comm 2>/dev/null | awk '$3=="openclaw" && $2==1 {print $1}'); do
            [[ "$_pid" == "$GW_PARENT" ]] && continue
            ORPHAN_PIDS="$ORPHAN_PIDS $_pid"
        done
        ORPHAN_N=0
        for opid in $ORPHAN_PIDS; do
            if ! $DRY_RUN; then
                kill -TERM "$opid" 2>/dev/null
            fi
            ORPHAN_N=$((ORPHAN_N + 1))
        done
        if [[ "$ORPHAN_N" -gt 0 ]]; then
            if $DRY_RUN; then
                log "[DRY-RUN] Would kill $ORPHAN_N orphan openclaw processes (PPID=1)"
            else
                sleep 2
                for opid in $(ps -eo pid,ppid,comm 2>/dev/null | awk '$3=="openclaw" && $2==1 {print $1}'); do
                    [[ -n "$GW_PARENT" ]] && [[ "$opid" == "$GW_PARENT" ]] && continue
                    kill -9 "$opid" 2>/dev/null
                done
                log "[ORPHAN-GC] Killed $ORPHAN_N orphan openclaw processes (PPID=1)"
            fi
        fi
    fi

    # 0b: Swap 保护 (>80% 立即紧急清理)
    SWAP_INFO=$(sysctl vm.swapusage 2>/dev/null)
    if [[ -n "$SWAP_INFO" ]]; then
        SWAP_TOTAL=$(echo "$SWAP_INFO" | grep -oE 'total = [0-9.]+' | grep -oE '[0-9.]+')
        SWAP_USED=$(echo "$SWAP_INFO" | grep -oE 'used = [0-9.]+' | grep -oE '[0-9.]+')
        if [[ -n "$SWAP_TOTAL" ]] && [[ -n "$SWAP_USED" ]]; then
            SWAP_PCT=$(python3 -c "t=float('${SWAP_TOTAL}');u=float('${SWAP_USED}');print(int(u*100/t) if t>0 else 0)" 2>/dev/null || echo 0)
            if [[ "$SWAP_PCT" -gt 80 ]]; then
                log "[EMERGENCY] Swap ${SWAP_PCT}% (${SWAP_USED}M/${SWAP_TOTAL}M) — force-killing orphans"
                GW_PARENT_E=$(ps -o ppid= -p "$(pgrep -f openclaw-gateway | head -1)" 2>/dev/null | tr -d ' ')
                if $DRY_RUN; then
                    log "[DRY-RUN] Would force-kill orphan openclaw processes due to high swap"
                else
                    for opid in $(ps -eo pid,ppid,comm 2>/dev/null | awk '$3=="openclaw" && $2==1 {print $1}'); do
                        [[ -n "$GW_PARENT_E" ]] && [[ "$opid" == "$GW_PARENT_E" ]] && continue
                        kill -9 "$opid" 2>/dev/null
                    done
                fi
                PROC_REMAIN=$(ps -eo comm 2>/dev/null | grep -c "^openclaw$")
                log "[EMERGENCY] Post-cleanup: $PROC_REMAIN openclaw processes remain"
            fi
        fi
    fi

    # 0c: 进程数保护 (>30 个 openclaw 进程 → 清理孤儿)
    PROC_COUNT=$(ps -eo comm 2>/dev/null | grep -c "^openclaw$")
    if [[ "$PROC_COUNT" -gt 30 ]]; then
        log "[MEMORY-WARN] openclaw process count: $PROC_COUNT (>30 threshold)"
        GW_PARENT_P=$(ps -o ppid= -p "$(pgrep -f openclaw-gateway | head -1)" 2>/dev/null | tr -d ' ')
        if $DRY_RUN; then
            log "[DRY-RUN] Would clean orphan openclaw processes because process count is high"
        else
            for opid in $(ps -eo pid,ppid,comm 2>/dev/null | awk '$3=="openclaw" && $2==1 {print $1}'); do
                [[ -n "$GW_PARENT_P" ]] && [[ "$opid" == "$GW_PARENT_P" ]] && continue
                kill -9 "$opid" 2>/dev/null
            done
        fi
        PROC_AFTER=$(ps -eo comm 2>/dev/null | grep -c "^openclaw$")
        log "[ORPHAN-GC] Emergency cleanup: $PROC_COUNT -> $PROC_AFTER openclaw processes"
    fi
}


# --- Step 0.5: Log rotation + Chrome orphan cleanup (runs every heartbeat) ---

# Log rotation: auto-rotate logs >10MB
for logf in "$LOG_DIR/gateway.err.log" "$LOG_DIR/gateway.log" "$LOG_DIR/browser-launcher.log"; do
    if [[ -f "$logf" ]]; then
        sz=$(stat -f%z "$logf" 2>/dev/null || echo 0)
        if (( sz > 10485760 )); then
            if $DRY_RUN; then
                log "[DRY-RUN] Would rotate $(basename "$logf") (currently $(( sz / 1048576 ))MB)"
            else
                mv "$logf" "${logf}.1"
                : > "$logf"
                log "[LOG-ROTATE] Rotated $(basename "$logf") (was $(( sz / 1048576 ))MB)"
            fi
        fi
    fi
done
# Clean rotated logs older than 7 days
if $DRY_RUN; then
    old_rotated=$(find "$LOG_DIR" -name '*.log.1' -mtime +7 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$old_rotated" -gt 0 ]]; then
        log "[DRY-RUN] Would remove $old_rotated old rotated log files"
    fi
else
    find "$LOG_DIR" -name '*.log.1' -mtime +7 -delete 2>/dev/null
fi

# Chrome orphan cleanup: kill PPID=1 Chrome instances not used by Gateway
GW_PID=$(get_port_owner_pid)
if [[ -n "$GW_PID" ]]; then
    GW_CHROME_PID=$(ps -eo pid,ppid,comm 2>/dev/null | awk -v gw="$GW_PID" '$2==gw && $3~/Google/ {print $1; exit}')
    for chrome_pid in $(ps -eo pid,ppid,comm 2>/dev/null | awk '$3~/Google Chrome/ && $2==1 {print $1}'); do
        if [[ -n "$GW_CHROME_PID" ]] && [[ "$chrome_pid" == "$GW_CHROME_PID" ]]; then
            continue
        fi
        child_count=$(ps -eo ppid 2>/dev/null | awk -v p="$chrome_pid" '$1==p' | wc -l | tr -d ' ')
        if (( child_count > 10 )); then
            if $DRY_RUN; then
                log "[DRY-RUN] Would kill orphan Chrome PID=$chrome_pid (had $child_count children)"
            else
                ps -eo pid,ppid 2>/dev/null | awk -v p="$chrome_pid" '$2==p {print $1}' | while read cpid; do kill -9 "$cpid" 2>/dev/null; done
                kill -9 "$chrome_pid" 2>/dev/null
                log "[CHROME-GC] Killed orphan Chrome PID=$chrome_pid (had $child_count children)"
            fi
        fi
    done
fi

# ─── Step 1: PID 状态检查 ───
pid_status=$(check_pid_status)
log "[INFO] PID status: $pid_status"

# ─── Step 2: 多层健康检查（HTTP + RPC + 退化信号） ───
http_status=$(check_http_health)
rpc_status=$(check_rpc_health)
degraded_status=$(check_degraded_signals)
log "[INFO] HTTP health: $http_status"
log "[INFO] RPC health: $rpc_status"
log "[INFO] Degraded signals: $degraded_status"

SERVICE_VERSION_DRIFT=false
if service_version_drift; then
    SERVICE_VERSION_DRIFT=true
fi

if [[ "$pid_status" == "NOT_LOADED" ]] && [[ "$http_status" == "OK" ]] && [[ "$rpc_status" == "OK" ]]; then
    log "[WARN] Gateway is reachable but LaunchAgent is not loaded; current uptime depends on a manual/unmanaged process"
fi

# ─── Step 3: 综合判断 Gateway 状态 ───
GATEWAY_HEALTHY=false
unhealthy_reason=""

if $SERVICE_VERSION_DRIFT && ([[ "$http_status" != "OK" ]] || [[ "$rpc_status" != "OK" ]] || is_config_error); then
    unhealthy_reason="SERVICE_VERSION_DRIFT"
elif [[ "$http_status" != "OK" ]]; then
    unhealthy_reason="HTTP_$http_status"
elif [[ "$rpc_status" != "OK" ]]; then
    unhealthy_reason="RPC_$rpc_status"
elif [[ "$degraded_status" != "NONE" ]]; then
    unhealthy_reason="$degraded_status"
fi

if [[ -z "$unhealthy_reason" ]]; then
    GATEWAY_HEALTHY=true
    log "[OK] Gateway healthy (HTTP+RPC pass, no degraded signals)"
    decrement_crash_count
    reset_doctor_fix_counter
    reset_unhealthy_streak
else
    ERRORS=$((ERRORS + 1))
    streak=$(increment_unhealthy_streak "$unhealthy_reason")
    log "[ERROR] Gateway unhealthy: PID=$pid_status, reason=$unhealthy_reason, streak=$streak"

    # 退化态要求连续 N 次命中才触发重启，减少误报抖动
    if [[ "$unhealthy_reason" == DEGRADED:* ]] && [[ "$streak" -lt "$DEGRADED_CONSECUTIVE_THRESHOLD" ]]; then
        log "[INFO] Degraded streak $streak/$DEGRADED_CONSECUTIVE_THRESHOLD, waiting next cycle before restart"
    else
        crash_count=$(get_crash_count)

        if is_in_cooldown; then
            log "[INFO] In backoff cooldown, skipping restart this cycle"
        else
            # 检查是否应该因当前原因触发重启（活跃时段策略）
            if ! should_restart_for_degraded "$unhealthy_reason"; then
                log "[SKIP-RESTART] DEGRADED detected in active hours ($ACTIVE_HOURS_START-$ACTIVE_HOURS_END $ACTIVE_HOURS_TZ), restart suppressed (reason=$unhealthy_reason, streak=$streak)"
            else
                if [[ $crash_count -ge $MAX_TOTAL_RETRIES ]]; then
                    log "[WARN] Crash count high ($crash_count/$MAX_TOTAL_RETRIES), still applying backoff"
                fi

            # 检查是否是 config 错误导致的启动失败
            if [[ "$pid_status" == STOPPED:exit_1 ]] || is_config_error; then
                log "[WARN] Config error pattern detected"

                if $SERVICE_VERSION_DRIFT; then
                    repair_gateway_service_install || true
                fi

                # 策略 1: 先尝试 openclaw doctor --fix
                if try_doctor_fix; then
                    log "[INFO] doctor --fix executed, will restart"
                fi

                # 策略 2: 如果 doctor --fix 已经用完次数，尝试 last-known-good 回滚
                fix_count=0
                if [[ -f "$DOCTOR_FIX_COUNTER_FILE" ]]; then
                    fix_count=$(cat "$DOCTOR_FIX_COUNTER_FILE")
                fi
                if [[ $fix_count -ge $MAX_DOCTOR_FIX ]]; then
                    log "[WARN] doctor --fix exhausted, trying last-known-good rollback"
                    if restore_last_known_good; then
                        RECOVERED=$((RECOVERED + 1))
                    else
                        # 降级：从定时备份恢复
                        log "[WARN] No last-known-good, trying auto backup"
                        LATEST_BACKUP=$(find_safe_config_backup || true)
                        if [[ -n "$LATEST_BACKUP" ]]; then
                            if $DRY_RUN; then
                                log "[DRY-RUN] Would restore from auto backup: $LATEST_BACKUP"
                            else
                                cp "$CONFIG_FILE" "$CONFIG_FILE.bad.$TIMESTAMP"
                                cp "$LATEST_BACKUP" "$CONFIG_FILE"
                                log "[RECOVERED] Restored from auto backup: $LATEST_BACKUP"
                            fi
                            RECOVERED=$((RECOVERED + 1))
                        else
                            log "[CRITICAL] No valid backup found!"
                        fi
                    fi
                fi
            fi

            # 执行重启
            increment_crash_count
            crash_count=$(get_crash_count)
            backoff=$(get_backoff_delay)
            log "[WARN] Crash count: $crash_count/$MAX_TOTAL_RETRIES (next backoff: ${backoff}s)"

            # 记录活跃时段状态（用于日志审计）
            if is_in_active_hours; then
                log "[INFO] Current time is in active hours ($ACTIVE_HOURS_START-$ACTIVE_HOURS_END $ACTIVE_HOURS_TZ)"
            else
                log "[INFO] Current time is outside active hours"
            fi

            request_restart "Unhealthy (PID=$pid_status, reason=$unhealthy_reason)"

            # 循环等待启动（最多30s，每5s检查一次）
            if $DRY_RUN; then
                log "[DRY-RUN] Would wait for Gateway startup after restart"
            else
                wait_max=30
                wait_interval=5
                waited=0
                post_restart_http=""
                post_restart_rpc=""
                while [[ $waited -lt $wait_max ]]; do
                    sleep $wait_interval
                    waited=$(($waited + $wait_interval))
                    post_restart_http=$(check_http_health)
                    post_restart_rpc=$(check_rpc_health)
                    if [[ "$post_restart_http" == "OK" ]] && [[ "$post_restart_rpc" == "OK" ]]; then
                        log "[RECOVERED] Gateway recovered after restart (waited ${waited}s)"
                        GATEWAY_HEALTHY=true
                        RECOVERED=$(($RECOVERED + 1))
                        reset_doctor_fix_counter
                        reset_unhealthy_streak
                        break
                    fi
                    log "[INFO] Waiting for Gateway startup... ${waited}s/${wait_max}s (HTTP=$post_restart_http, RPC=$post_restart_rpc)"
                done
                if [[ "$post_restart_http" != "OK" ]] || [[ "$post_restart_rpc" != "OK" ]]; then
                    log "[WARN] Gateway still unhealthy after ${wait_max}s (HTTP=$post_restart_http, RPC=$post_restart_rpc)"
                fi
            fi
            fi  # Close should_restart_for_degraded
        fi
    fi
fi

# ─── Step 4: openclaw.json 合法性检查 ───
CONFIG_VALID=0
if $PYTHON -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
    log "[OK] openclaw.json is valid JSON"
    if validate_current_config_schema; then
        log "[OK] openclaw.json passed schema validation"
        CONFIG_VALID=1
    else
        log "[ERROR] openclaw.json failed schema/compatibility validation"
        CONFIG_VALID=0
        ERRORS=$((ERRORS + 1))
        log "[RECOVER] Attempting to restore schema-safe openclaw.json from backup..."
        if restore_last_known_good; then
            RECOVERED=$((RECOVERED + 1))
            request_restart "Config restored from schema-safe last-known-good"
            wait_for_gateway_startup "schema-safe last-known-good restore"
            run_post_update
            CONFIG_VALID=1
        else
            LATEST_BACKUP=$(find_safe_config_backup || true)
            if [[ -n "$LATEST_BACKUP" ]]; then
                if $DRY_RUN; then
                    log "[DRY-RUN] Would restore schema-safe auto backup: $LATEST_BACKUP"
                else
                    cp "$CONFIG_FILE" "$CONFIG_FILE.bad-schema.$TIMESTAMP"
                    cp "$LATEST_BACKUP" "$CONFIG_FILE"
                    log "[RECOVERED] Restored schema-safe auto backup: $LATEST_BACKUP"
                fi
                RECOVERED=$((RECOVERED + 1))
                request_restart "Config restored from schema-safe auto backup"
                wait_for_gateway_startup "schema-safe auto backup restore"
                run_post_update
                CONFIG_VALID=1
            else
                log "[CRITICAL] No schema-safe backup found for openclaw.json"
            fi
        fi
    fi
else
    log "[ERROR] openclaw.json is INVALID JSON!"
    CONFIG_VALID=0
    ERRORS=$((ERRORS + 1))

    # JSON 语法错误：直接从备份恢复
    log "[RECOVER] Attempting to restore openclaw.json from backup..."
    if restore_last_known_good; then
        RECOVERED=$((RECOVERED + 1))
        request_restart "Config restored from last-known-good"
        wait_for_gateway_startup "last-known-good restore"
        run_post_update
        CONFIG_VALID=1
    else
        LATEST_BACKUP=$(find_safe_config_backup || true)
        if [[ -n "$LATEST_BACKUP" ]]; then
            if $DRY_RUN; then
                log "[DRY-RUN] Would restore from $LATEST_BACKUP"
            else
                cp "$CONFIG_FILE" "$CONFIG_FILE.corrupted.$TIMESTAMP"
                cp "$LATEST_BACKUP" "$CONFIG_FILE"
                log "[RECOVERED] Restored from $LATEST_BACKUP"
            fi
            RECOVERED=$((RECOVERED + 1))
            request_restart "Config restored from auto backup"
            wait_for_gateway_startup "auto backup restore"
            run_post_update
            CONFIG_VALID=1
        else
            log "[CRITICAL] No valid backup found for openclaw.json"
        fi
    fi
fi

# ─── Step 5: cron/jobs.json 合法性检查 ───
CRON_VALID=0
if $PYTHON -c "import json; json.load(open('$CRON_FILE'))" 2>/dev/null; then
    log "[OK] cron/jobs.json is valid JSON"
    CRON_VALID=1
else
    log "[ERROR] cron/jobs.json is INVALID JSON!"
    CRON_VALID=0
    ERRORS=$((ERRORS + 1))
    LATEST_CRON_BACKUP=$(ls -t "$BACKUP_DIR"/jobs.json.* 2>/dev/null | head -1)
    if [[ -n "$LATEST_CRON_BACKUP" ]] && $PYTHON -c "import json; json.load(open('$LATEST_CRON_BACKUP'))" 2>/dev/null; then
        if $DRY_RUN; then
            log "[DRY-RUN] Would restore cron/jobs.json from $LATEST_CRON_BACKUP"
        else
            cp "$CRON_FILE" "$CRON_FILE.corrupted.$TIMESTAMP"
            cp "$LATEST_CRON_BACKUP" "$CRON_FILE"
            log "[RECOVERED] Restored cron/jobs.json from $LATEST_CRON_BACKUP"
        fi
        RECOVERED=$((RECOVERED + 1))
    else
        log "[CRITICAL] No valid backup found for cron/jobs.json"
    fi
fi

# ─── Step 6: 关键配置字段检查 ───
if [[ $CONFIG_VALID -eq 1 ]]; then
    AGENT_COUNT=$($PYTHON -c "import json; d=json.load(open('$CONFIG_FILE')); print(len(d.get('agents',{}).get('list',[])))" 2>/dev/null)
    ACP_ENABLED=$($PYTHON -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('acp',{}).get('enabled',''))" 2>/dev/null)
    GATEWAY_PORT_CFG=$($PYTHON -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('gateway',{}).get('port',''))" 2>/dev/null)

    if [[ "$AGENT_COUNT" -lt 3 ]] 2>/dev/null; then
        log "[ERROR] Agent count too low: $AGENT_COUNT (expected >=3)"
        ERRORS=$((ERRORS + 1))
    else
        log "[OK] Agent count: $AGENT_COUNT"
    fi

    if [[ "$ACP_ENABLED" != "True" ]]; then
        log "[WARN] ACP not enabled: $ACP_ENABLED"
    fi

    if [[ "$GATEWAY_PORT_CFG" != "18789" ]] && [[ -n "$GATEWAY_PORT_CFG" ]]; then
        log "[WARN] Gateway port changed: $GATEWAY_PORT_CFG (expected 18789)"
    fi
fi

# ─── Step 7: 配置备份 ───
if [[ $CONFIG_VALID -eq 1 ]]; then
    if $DRY_RUN; then
        log "[DRY-RUN] Would back up openclaw.json"
    else
        cp "$CONFIG_FILE" "$BACKUP_DIR/openclaw.json.$TIMESTAMP"
        log "[BACKUP] openclaw.json backed up"
    fi

    # 如果 Gateway 健康，同时保存为 last-known-good
    if $GATEWAY_HEALTHY; then
        save_last_known_good
    fi
fi

if [[ $CRON_VALID -eq 1 ]]; then
    if $DRY_RUN; then
        log "[DRY-RUN] Would back up cron/jobs.json"
    else
        cp "$CRON_FILE" "$BACKUP_DIR/jobs.json.$TIMESTAMP"
        log "[BACKUP] cron/jobs.json backed up"
    fi
fi

# ─── Step 8: 清理过期备份 ───
for PREFIX in openclaw.json jobs.json; do
    BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/${PREFIX}.* 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]]; then
        EXCESS=$((BACKUP_COUNT - MAX_BACKUPS))
        if $DRY_RUN; then
            log "[DRY-RUN] Would remove $EXCESS old $PREFIX backups"
        else
            ls -1t "$BACKUP_DIR"/${PREFIX}.* | tail -$EXCESS | xargs rm -f
            log "[CLEANUP] Removed $EXCESS old $PREFIX backups"
        fi
    fi
done


# ─── Step 8.5: Session 垃圾清理（每日执行一次） ───
SESSION_GC_MARKER="$STATE_DIR/last_session_gc"
SESSION_GC_INTERVAL=86400  # 24 hours

should_run_session_gc=false
if [[ ! -f "$SESSION_GC_MARKER" ]]; then
    should_run_session_gc=true
else
    last_gc=$(cat "$SESSION_GC_MARKER" 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    elapsed=$((now_epoch - last_gc))
    if [[ $elapsed -ge $SESSION_GC_INTERVAL ]]; then
        should_run_session_gc=true
    fi
fi

if $should_run_session_gc; then
    log "[SESSION-GC] Starting session garbage collection..."

    gc_deleted=$(find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.deleted.*" 2>/dev/null | wc -l | tr -d ' ')
    gc_purged=$(find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.purged" 2>/dev/null | wc -l | tr -d ' ')
    gc_reset=$(find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.reset.*" 2>/dev/null | wc -l | tr -d ' ')
    gc_bak=$(find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.bak*" -type f 2>/dev/null | wc -l | tr -d ' ')
    gc_tmp=$(find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.tmp" -type f 2>/dev/null | wc -l | tr -d ' ')
    gc_total=$((gc_deleted + gc_purged + gc_reset + gc_bak + gc_tmp))

    if [[ $gc_total -gt 0 ]]; then
        if $DRY_RUN; then
            log "[DRY-RUN] Would clean $gc_total dead session files (deleted=$gc_deleted purged=$gc_purged reset=$gc_reset bak=$gc_bak tmp=$gc_tmp)"
        else
            find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.deleted.*" -delete 2>/dev/null
            find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.purged" -delete 2>/dev/null
            find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.reset.*" -delete 2>/dev/null
            find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.bak*" -type f -delete 2>/dev/null
            find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.tmp" -type f -delete 2>/dev/null
            log "[SESSION-GC] Cleaned $gc_total dead session files (deleted=$gc_deleted purged=$gc_purged reset=$gc_reset bak=$gc_bak tmp=$gc_tmp)"
        fi
    else
        log "[SESSION-GC] No dead session files found"
    fi

    active_sessions=$(find "$OPENCLAW_DIR/agents"/*/sessions/ -name "*.jsonl" -type f 2>/dev/null | wc -l | tr -d ' ')
    log "[SESSION-GC] Active session files remaining: $active_sessions"



    # ── Orphan openclaw process 清理 ──
    # 重启后旧的子进程可能不会被正确清理，导致内存泄漏
    GATEWAY_PID=$(pgrep -f "openclaw-gateway" 2>/dev/null | head -1)
    if [[ -n "$GATEWAY_PID" ]]; then
        # 统计所有 openclaw 进程（排除 gateway 本身和 chrome）
        OPENCLAW_PROCS=$(ps aux | grep -E "^\S+\s+\d+.*openclaw" | grep -v "grep\|openclaw-gateway\|Google Chrome" | awk '{print $2}' | sort -n)
        GATEWAY_PARENT=$(ps -o ppid= -p "$GATEWAY_PID" 2>/dev/null | tr -d ' ')
        
        ORPHAN_COUNT=0
        for pid in $OPENCLAW_PROCS; do
            # 跳过 gateway 进程和它的直接父进程
            [[ "$pid" == "$GATEWAY_PID" ]] && continue
            [[ "$pid" == "$GATEWAY_PARENT" ]] && continue
            
            # 检查此进程的父进程是否是当前 gateway
            PROC_PPID=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            if [[ "$PROC_PPID" == "1" ]] || { [[ "$PROC_PPID" != "$GATEWAY_PID" ]] && [[ "$PROC_PPID" != "$GATEWAY_PARENT" ]]; }; then
                # 父进程不是当前 gateway，也不是 init，可能是旧的残留
                # 再确认：进程启动时间比 gateway 早超过 5 分钟
                PROC_START=$(ps -o lstart= -p "$pid" 2>/dev/null)
                GW_START=$(ps -o lstart= -p "$GATEWAY_PID" 2>/dev/null)
                if [[ -n "$PROC_START" ]] && [[ -n "$GW_START" ]]; then
                    PROC_TS=$(date -j -f "%a %b %d %T %Y" "$PROC_START" +%s 2>/dev/null || echo 0)
                    GW_TS=$(date -j -f "%a %b %d %T %Y" "$GW_START" +%s 2>/dev/null || echo 0)
                    DIFF=$(( GW_TS - PROC_TS ))
                    if [[ "$DIFF" -gt 300 ]]; then
                        if $DRY_RUN; then
                            log "[DRY-RUN] Would kill orphan openclaw PID $pid (started ${DIFF}s before gateway)"
                        else
                            log "[ORPHAN-GC] Killing orphan openclaw PID $pid (started ${DIFF}s before gateway)"
                            kill -9 "$pid" 2>/dev/null
                        fi
                        ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
                    fi
                fi
            fi
        done
        
        if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
            log "[ORPHAN-GC] Cleaned $ORPHAN_COUNT orphan openclaw processes"
        fi
        
        # 内存保护：如果 openclaw 总内存占比超过 50%，告警
        TOTAL_MEM=$(ps aux | grep -E "openclaw" | grep -v grep | awk '{sum+=$4} END {printf "%.0f", sum}')
        if [[ -n "$TOTAL_MEM" ]] && [[ "$TOTAL_MEM" -gt 50 ]]; then
            log "[MEMORY-WARN] openclaw total memory usage: ${TOTAL_MEM}% (threshold: 50%)"
        fi
    fi

    # ── ACP session zombie 清理 ──
    # 清理 acpx 后端残留的 session 文件 (Issue #34054 workaround)
    ACPX_SESSIONS="$HOME/.acpx/sessions"
    if [[ -d "$ACPX_SESSIONS" ]]; then
        acpx_count=$(find "$ACPX_SESSIONS" -name "*.json" -not -name "index.json" -type f -mmin +60 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$acpx_count" -gt 0 ]]; then
            if $DRY_RUN; then
                log "[DRY-RUN] Would clean $acpx_count stale acpx session files (>1h old)"
            else
                find "$ACPX_SESSIONS" -name "*.json" -not -name "index.json" -type f -mmin +60 -delete 2>/dev/null
                find "$ACPX_SESSIONS" -name "*.ndjson" -type f -mmin +60 -delete 2>/dev/null
                log "[SESSION-GC] Cleaned $acpx_count stale acpx session files (>1h old)"
            fi
        fi
    fi

    # 清理 agents/*/sessions/sessions.json 中的 zombie ACP entries
    for sj in "$OPENCLAW_DIR"/agents/*/sessions/sessions.json; do
        if [[ -f "$sj" ]]; then
            acp_count=$(python3 -c "
import json
with open('$sj') as f:
    d = json.load(f)
if isinstance(d, dict):
    print(len([k for k in d if ':acp:' in k]))
else:
    print(0)
" 2>/dev/null)
            if [[ "$acp_count" -gt 0 ]]; then
                if $DRY_RUN; then
                    agent_name=$(basename "$(dirname "$(dirname "$sj")")")
                    log "[DRY-RUN] Would remove $acp_count zombie ACP entries from $agent_name/sessions.json"
                else
                    python3 -c "
import json
with open('$sj') as f:
    d = json.load(f)
if isinstance(d, dict):
    cleaned = {k:v for k,v in d.items() if ':acp:' not in k}
    with open('$sj','w') as f:
        json.dump(cleaned, f, indent=2)
" 2>/dev/null
                agent_name=$(basename "$(dirname "$(dirname "$sj")")")
                log "[SESSION-GC] Removed $acp_count zombie ACP entries from $agent_name/sessions.json"
                fi
            fi
        fi
    done

    # Check disk budget warning frequency
    disk_warn_count=$(grep -c "session disk budget exceeded" "$ERR_LOG" 2>/dev/null || echo 0)
    if [[ "$disk_warn_count" -gt 50 ]]; then
        log "[SESSION-GC] WARNING: $disk_warn_count disk budget warnings in gateway.err.log — consider session purge"
    fi

    if $DRY_RUN; then
        log "[DRY-RUN] Would update session GC marker"
    else
        mkdir -p "$STATE_DIR"
        date +%s > "$SESSION_GC_MARKER"
    fi
fi

# ─── Step 8.5: Claude 进程数监控 + 自动清理（防 fork 炸弹） ───
CLAUDE_COUNT=$(pgrep -cf "claude" 2>/dev/null || echo 0)
RUNNER_COUNT=$(pgrep -cf "subagent_claude_runner" 2>/dev/null || echo 0)

if [[ "$CLAUDE_COUNT" -gt "$MAX_CLAUDE_PROCESSES" ]]; then
    log "[FORK-BOMB] CRITICAL: claude process count ($CLAUDE_COUNT) exceeds limit ($MAX_CLAUDE_PROCESSES)!"
    log "[FORK-BOMB] subagent_claude_runner count: $RUNNER_COUNT"
    log "[FORK-BOMB] Initiating emergency cleanup..."

    if $DRY_RUN; then
        log "[DRY-RUN] Would clean up subagent runner processes"
    else
        pkill -f "subagent_claude_runner" 2>/dev/null || true
        pkill -f "run_subagent_claude" 2>/dev/null || true
        sleep 2
    fi

    AFTER_COUNT=$(pgrep -cf "claude" 2>/dev/null || echo 0)
    if [[ "$AFTER_COUNT" -gt "$MAX_CLAUDE_PROCESSES" ]]; then
        log "[FORK-BOMB] Still $AFTER_COUNT claude processes after runner cleanup. Killing orphan claude processes..."
        if $DRY_RUN; then
            log "[DRY-RUN] Would kill orphan claude print processes and pytest orchestrators"
        else
            pgrep -f "claude.*--permission-mode bypassPermissions --print" 2>/dev/null | while read pid; do
                PROC_AGE=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
                kill "$pid" 2>/dev/null
            done

            pkill -f "pytest.*orchestrator" 2>/dev/null || true
        fi
    fi

    FINAL_COUNT=$(pgrep -cf "claude" 2>/dev/null || echo 0)
    log "[FORK-BOMB] Cleanup complete. claude processes: $CLAUDE_COUNT → $FINAL_COUNT"
    ERRORS=$((ERRORS + 1))
elif [[ "$CLAUDE_COUNT" -gt "$CLAUDE_PROCESS_WARN_THRESHOLD" ]]; then
    log "[WARN] claude process count elevated: $CLAUDE_COUNT (warn=$CLAUDE_PROCESS_WARN_THRESHOLD, limit=$MAX_CLAUDE_PROCESSES)"
else
    log "[OK] claude process count: $CLAUDE_COUNT (limit=$MAX_CLAUDE_PROCESSES)"
fi

# ─── Step 9: 日志轮转 ───
if [[ -f "$LOG_FILE" ]]; then
    LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
    if [[ "$LINE_COUNT" -gt 2000 ]]; then
        if $DRY_RUN; then
            log "[DRY-RUN] Would rotate guardian.log (was $LINE_COUNT lines)"
        else
            tail -1000 "$LOG_FILE" > "$LOG_FILE.tmp"
            mv "$LOG_FILE.tmp" "$LOG_FILE"
            log "[CLEANUP] Log rotated (was $LINE_COUNT lines)"
        fi
    fi
fi

log "=== Guardian v2 heartbeat done: errors=$ERRORS recovered=$RECOVERED ==="
