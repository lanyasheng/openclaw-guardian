#!/bin/bash
# ============================================================================
# Guardian v2 单元测试脚本
# 测试 heartbeat-guardian.sh 中的所有工具函数和关键逻辑
# 用法: bash ~/.openclaw/scripts/test-guardian.sh
# ============================================================================

set -euo pipefail

# ============================================================================
# 测试框架
# ============================================================================
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg"
        echo -e "    ${RED}expected: '$expected'${NC}"
        echo -e "    ${RED}actual:   '$actual'${NC}"
    fi
}

assert_true() {
    local condition="$1"
    local msg="${2:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$condition"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (condition: $condition)"
    fi
}

assert_false() {
    local condition="$1"
    local msg="${2:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! eval "$condition"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (expected false, got true)"
    fi
}

assert_file_exists() {
    local filepath="$1"
    local msg="${2:-file exists: $filepath}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -f "$filepath" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (file not found)"
    fi
}

assert_file_not_exists() {
    local filepath="$1"
    local msg="${2:-file not exists: $filepath}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ ! -f "$filepath" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}✗${NC} $msg (file unexpectedly exists)"
    fi
}

describe() {
    CURRENT_TEST="$1"
    echo -e "\n${CYAN}▸ $1${NC}"
}

# ============================================================================
# 测试环境搭建
# ============================================================================
TEST_DIR=$(mktemp -d /tmp/guardian-test.XXXXXX)
OPENCLAW_DIR="$TEST_DIR/.openclaw"
BACKUP_DIR="$OPENCLAW_DIR/backups/auto"
LAST_KNOWN_GOOD_DIR="$OPENCLAW_DIR/backups/last-known-good"
CONFIG_FILE="$OPENCLAW_DIR/openclaw.json"
CRON_FILE="$OPENCLAW_DIR/cron/jobs.json"
LOG_FILE="$OPENCLAW_DIR/logs/guardian.log"
ERR_LOG="$OPENCLAW_DIR/logs/gateway.err.log"
STATE_DIR="$OPENCLAW_DIR/watchdog"
PYTHON=/opt/homebrew/bin/python3.12

GATEWAY_PORT=18789
HEALTH_TIMEOUT=5
DEGRADED_LOG_WINDOW_SECONDS=180
DEGRADED_ERROR_THRESHOLD=8
MAX_BACKUPS=24
MAX_TOTAL_RETRIES=6
CRASH_DECAY_HOURS=6
MAX_DOCTOR_FIX=2
BACKOFF_DELAYS=(60 120 300 600 900 1800)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DRY_RUN=true
LAUNCHD_SERVICE="ai.openclaw.gateway"

CRASH_COUNTER_FILE="$STATE_DIR/crash-counter"
CRASH_TIMESTAMP_FILE="$STATE_DIR/crash-timestamp"
COOLDOWN_FILE="$STATE_DIR/last-restart"
DOCTOR_FIX_COUNTER_FILE="$STATE_DIR/doctor-fix-attempts"
UNHEALTHY_STREAK_FILE="$STATE_DIR/unhealthy-streak"
UNHEALTHY_REASON_FILE="$STATE_DIR/unhealthy-reason"
HEALING_LOCK="$TEST_DIR/guardian-test.lock"

mkdir -p "$BACKUP_DIR" "$LAST_KNOWN_GOOD_DIR" "$STATE_DIR" "$OPENCLAW_DIR/logs" "$OPENCLAW_DIR/cron"

# 创建有效的测试配置文件
cat > "$CONFIG_FILE" << 'TESTJSON'
{
    "agents": {
        "list": [
            {"name": "agent1"},
            {"name": "agent2"},
            {"name": "agent3"},
            {"name": "agent4"}
        ]
    },
    "acp": {"enabled": true},
    "gateway": {"port": 18789}
}
TESTJSON

cat > "$CRON_FILE" << 'TESTJSON'
{"jobs": [{"name": "test"}]}
TESTJSON

# ============================================================================
# 从 guardian 脚本中提取工具函数（不执行主逻辑）
# ============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# --- Crash 计数器 ---
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
        echo "0" > "$CRASH_COUNTER_FILE"
        rm -f "$CRASH_TIMESTAMP_FILE"
    fi
}

increment_crash_count() {
    local count=$(get_crash_count)
    echo $((count + 1)) > "$CRASH_COUNTER_FILE"
    date +%s > "$CRASH_TIMESTAMP_FILE"
}

decrement_crash_count() {
    local count=$(get_crash_count)
    if [[ $count -gt 0 ]]; then
        echo $((count - 1)) > "$CRASH_COUNTER_FILE"
    fi
}

reset_crash_count() {
    echo "0" > "$CRASH_COUNTER_FILE"
    rm -f "$CRASH_TIMESTAMP_FILE"
}

# --- 指数退避 ---
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
        return 0
    fi
    return 1
}

set_last_restart() {
    date +%s > "$COOLDOWN_FILE"
}

# --- 并发锁 ---
acquire_healing_lock() {
    if mkdir "$HEALING_LOCK" 2>/dev/null; then
        trap "rmdir '$HEALING_LOCK' 2>/dev/null || true" EXIT
        return 0
    fi
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

# --- doctor --fix ---
try_doctor_fix() {
    local fix_count=0
    if [[ -f "$DOCTOR_FIX_COUNTER_FILE" ]]; then
        fix_count=$(cat "$DOCTOR_FIX_COUNTER_FILE")
    fi
    if [[ $fix_count -ge $MAX_DOCTOR_FIX ]]; then
        return 1
    fi
    echo $((fix_count + 1)) > "$DOCTOR_FIX_COUNTER_FILE"
    return 0
}

reset_doctor_fix_counter() {
    rm -f "$DOCTOR_FIX_COUNTER_FILE"
}

# --- 连续异常计数 ---
get_unhealthy_streak() {
    if [[ -f "$UNHEALTHY_STREAK_FILE" ]]; then
        cat "$UNHEALTHY_STREAK_FILE"
    else
        echo "0"
    fi
}

reset_unhealthy_streak() {
    echo "0" > "$UNHEALTHY_STREAK_FILE"
    rm -f "$UNHEALTHY_REASON_FILE"
}

increment_unhealthy_streak() {
    local reason="$1"
    local count=$(get_unhealthy_streak)
    count=$((count + 1))
    echo "$count" > "$UNHEALTHY_STREAK_FILE"
    echo "$reason" > "$UNHEALTHY_REASON_FILE"
    echo "$count"
}

# --- Last-Known-Good ---
save_last_known_good() {
    cp "$CONFIG_FILE" "$LAST_KNOWN_GOOD_DIR/openclaw.json"
}

restore_last_known_good() {
    local lkg_file="$LAST_KNOWN_GOOD_DIR/openclaw.json"
    if [[ -f "$lkg_file" ]] && $PYTHON -c "import json; json.load(open('$lkg_file'))" 2>/dev/null; then
        cp "$CONFIG_FILE" "$CONFIG_FILE.bad.$TIMESTAMP"
        cp "$lkg_file" "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# --- Config 错误检测 ---
is_config_error() {
    if [[ ! -f "$ERR_LOG" ]]; then
        return 1
    fi
    tail -50 "$ERR_LOG" 2>/dev/null | grep -qi "config invalid\|unrecognized key\|doctor --fix\|invalid config\|schema\|validation failed" 2>/dev/null
}

# --- 退化信号检测 ---
check_degraded_signals() {
    if [[ ! -f "$ERR_LOG" ]]; then
        echo "NONE"
        return
    fi
    local now=$(date +%s)
    local mtime=$(stat -f %m "$ERR_LOG" 2>/dev/null || echo "0")
    local age=$((now - mtime))
    if [[ "$age" -gt "$DEGRADED_LOG_WINDOW_SECONDS" ]]; then
        echo "NONE"
        return
    fi
    local sample
    sample=$(tail -200 "$ERR_LOG" 2>/dev/null || true)
    local severe
    severe=$(printf "%s\n" "$sample" | grep -E "embedded run timeout|FailoverError: LLM request timed out|lane wait exceeded|gateway closed \(1006|abnormal closure|Slow listener detected: DiscordMessageListener took [1-9][0-9]{2,}" | wc -l | tr -d ' ')
    if [[ "$severe" -ge "$DEGRADED_ERROR_THRESHOLD" ]]; then
        echo "DEGRADED:$severe"
    else
        echo "NONE"
    fi
}

# ============================================================================
# 测试开始
# ============================================================================
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Guardian v2 单元测试${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"

# ────────────────────────────────────────────────────────────────
# 1. Crash 计数器测试
# ────────────────────────────────────────────────────────────────
describe "Crash Counter - 初始状态"
assert_eq "0" "$(get_crash_count)" "初始 crash count 为 0"

describe "Crash Counter - 递增"
increment_crash_count
assert_eq "1" "$(get_crash_count)" "递增后 crash count 为 1"
increment_crash_count
assert_eq "2" "$(get_crash_count)" "再次递增后 crash count 为 2"
assert_file_exists "$CRASH_TIMESTAMP_FILE" "crash timestamp 文件已创建"

describe "Crash Counter - 递减"
decrement_crash_count
assert_eq "1" "$(get_crash_count)" "递减后 crash count 为 1"

describe "Crash Counter - 递减不低于 0"
reset_crash_count
decrement_crash_count
assert_eq "0" "$(get_crash_count)" "从 0 递减仍为 0"

describe "Crash Counter - 重置"
increment_crash_count
increment_crash_count
increment_crash_count
reset_crash_count
assert_eq "0" "$(get_crash_count)" "重置后 crash count 为 0"
assert_file_not_exists "$CRASH_TIMESTAMP_FILE" "crash timestamp 文件已删除"

describe "Crash Counter - 自动衰减（模拟过期）"
increment_crash_count
increment_crash_count
# 模拟 7 小时前的 timestamp（超过 CRASH_DECAY_HOURS=6）
echo $(( $(date +%s) - 25200 )) > "$CRASH_TIMESTAMP_FILE"
check_crash_decay
assert_eq "0" "$(get_crash_count)" "衰减后 crash count 重置为 0"
assert_file_not_exists "$CRASH_TIMESTAMP_FILE" "衰减后 timestamp 文件已删除"

describe "Crash Counter - 未过期不衰减"
increment_crash_count
increment_crash_count
# 模拟 1 小时前的 timestamp（未超过 CRASH_DECAY_HOURS=6）
echo $(( $(date +%s) - 3600 )) > "$CRASH_TIMESTAMP_FILE"
check_crash_decay
assert_eq "2" "$(get_crash_count)" "未过期时 crash count 保持不变"

# 清理
reset_crash_count

# ────────────────────────────────────────────────────────────────
# 2. 指数退避测试
# ────────────────────────────────────────────────────────────────
describe "Backoff - crash count=0 时返回第一级延迟"
assert_eq "60" "$(get_backoff_delay)" "crash=0 → 60s"

describe "Backoff - 逐级递增"
increment_crash_count  # count=1
assert_eq "60" "$(get_backoff_delay)" "crash=1 → 60s (index=0)"
increment_crash_count  # count=2
assert_eq "120" "$(get_backoff_delay)" "crash=2 → 120s (index=1)"
increment_crash_count  # count=3
assert_eq "300" "$(get_backoff_delay)" "crash=3 → 300s (index=2)"
increment_crash_count  # count=4
assert_eq "600" "$(get_backoff_delay)" "crash=4 → 600s (index=3)"
increment_crash_count  # count=5
assert_eq "900" "$(get_backoff_delay)" "crash=5 → 900s (index=4)"
increment_crash_count  # count=6
assert_eq "1800" "$(get_backoff_delay)" "crash=6 → 1800s (index=5, max)"

describe "Backoff - 超出数组边界时使用最大值"
increment_crash_count  # count=7
assert_eq "1800" "$(get_backoff_delay)" "crash=7 → 1800s (capped at max)"
increment_crash_count  # count=8
assert_eq "1800" "$(get_backoff_delay)" "crash=8 → 1800s (capped at max)"

# 清理
reset_crash_count

# ────────────────────────────────────────────────────────────────
# 3. Cooldown 测试
# ────────────────────────────────────────────────────────────────
describe "Cooldown - 无 cooldown 文件时不在冷却中"
rm -f "$COOLDOWN_FILE"
assert_false "is_in_cooldown" "无 cooldown 文件 → 不在冷却中"

describe "Cooldown - 刚重启后在冷却中"
set_last_restart
increment_crash_count  # 需要 count>=1 才有有效的 backoff
assert_true "is_in_cooldown" "刚重启 → 在冷却中"

describe "Cooldown - 过期后不在冷却中"
# 模拟 2 小时前重启（远超 60s 的 backoff）
echo $(( $(date +%s) - 7200 )) > "$COOLDOWN_FILE"
assert_false "is_in_cooldown" "2 小时前重启 → 冷却已过期"

# 清理
reset_crash_count
rm -f "$COOLDOWN_FILE"

# ────────────────────────────────────────────────────────────────
# 4. 并发锁测试
# ────────────────────────────────────────────────────────────────
describe "Lock - 首次获取成功"
rmdir "$HEALING_LOCK" 2>/dev/null || true
assert_true "acquire_healing_lock" "首次获取锁成功"

describe "Lock - 重复获取失败"
assert_false "acquire_healing_lock" "锁已存在 → 获取失败"

describe "Lock - 释放后可重新获取"
rmdir "$HEALING_LOCK" 2>/dev/null || true
assert_true "acquire_healing_lock" "释放后重新获取成功"

describe "Lock - stale lock 检测（模拟 >10 分钟）"
rmdir "$HEALING_LOCK" 2>/dev/null || true
mkdir "$HEALING_LOCK"
# 修改 lock 目录的时间戳为 15 分钟前
touch -t $(date -v-15M +%Y%m%d%H%M.%S) "$HEALING_LOCK"
assert_true "acquire_healing_lock" "stale lock (>10min) → 强制获取成功"

# 清理
rmdir "$HEALING_LOCK" 2>/dev/null || true

# ────────────────────────────────────────────────────────────────
# 5. Doctor Fix 计数器测试
# ────────────────────────────────────────────────────────────────
describe "Doctor Fix - 初始可执行"
rm -f "$DOCTOR_FIX_COUNTER_FILE"
assert_true "try_doctor_fix" "第 1 次 doctor --fix 成功"
assert_eq "1" "$(cat "$DOCTOR_FIX_COUNTER_FILE")" "计数器为 1"

describe "Doctor Fix - 第二次可执行"
assert_true "try_doctor_fix" "第 2 次 doctor --fix 成功"
assert_eq "2" "$(cat "$DOCTOR_FIX_COUNTER_FILE")" "计数器为 2"

describe "Doctor Fix - 超过限制后拒绝"
assert_false "try_doctor_fix" "第 3 次 doctor --fix 被拒绝 (MAX=2)"

describe "Doctor Fix - 重置后可再次执行"
reset_doctor_fix_counter
assert_file_not_exists "$DOCTOR_FIX_COUNTER_FILE" "计数器文件已删除"
assert_true "try_doctor_fix" "重置后 doctor --fix 成功"

# 清理
reset_doctor_fix_counter

# ────────────────────────────────────────────────────────────────
# 6. Last-Known-Good 配置管理测试
# ────────────────────────────────────────────────────────────────
describe "LKG - 保存 last-known-good"
save_last_known_good
assert_file_exists "$LAST_KNOWN_GOOD_DIR/openclaw.json" "LKG 文件已创建"
local_lkg_content=$(cat "$LAST_KNOWN_GOOD_DIR/openclaw.json")
local_cfg_content=$(cat "$CONFIG_FILE")
assert_eq "$local_cfg_content" "$local_lkg_content" "LKG 内容与当前配置一致"

describe "LKG - 从 LKG 恢复损坏的配置"
# 破坏当前配置
echo "INVALID JSON {{{" > "$CONFIG_FILE"
assert_true "restore_last_known_good" "从 LKG 恢复成功"
# 验证恢复后的配置是有效 JSON
assert_true "$PYTHON -c \"import json; json.load(open('$CONFIG_FILE'))\" 2>/dev/null" "恢复后配置是有效 JSON"
assert_file_exists "$CONFIG_FILE.bad.$TIMESTAMP" "损坏的配置已备份为 .bad"

describe "LKG - 无 LKG 文件时恢复失败"
rm -f "$LAST_KNOWN_GOOD_DIR/openclaw.json"
echo "BROKEN" > "$CONFIG_FILE"
assert_false "restore_last_known_good" "无 LKG 文件 → 恢复失败"

describe "LKG - LKG 文件本身损坏时恢复失败"
echo "ALSO BROKEN" > "$LAST_KNOWN_GOOD_DIR/openclaw.json"
assert_false "restore_last_known_good" "LKG 文件损坏 → 恢复失败"

# 恢复有效配置
cat > "$CONFIG_FILE" << 'TESTJSON'
{
    "agents": {
        "list": [
            {"name": "agent1"},
            {"name": "agent2"},
            {"name": "agent3"},
            {"name": "agent4"}
        ]
    },
    "acp": {"enabled": true},
    "gateway": {"port": 18789}
}
TESTJSON
save_last_known_good

# ────────────────────────────────────────────────────────────────
# 7. Config 错误检测测试
# ────────────────────────────────────────────────────────────────
describe "Config Error - 无 err log 时返回 false"
rm -f "$ERR_LOG"
assert_false "is_config_error" "无 err log → 非 config 错误"

describe "Config Error - 有 config invalid 关键字时返回 true"
echo "Error: config invalid at line 5" > "$ERR_LOG"
assert_true "is_config_error" "包含 'config invalid' → 检测到 config 错误"

describe "Config Error - 有 unrecognized key 关键字时返回 true"
echo "Warning: unrecognized key 'foo'" > "$ERR_LOG"
assert_true "is_config_error" "包含 'unrecognized key' → 检测到 config 错误"

describe "Config Error - 有 validation failed 关键字时返回 true"
echo "Schema validation failed for field 'port'" > "$ERR_LOG"
assert_true "is_config_error" "包含 'validation failed' → 检测到 config 错误"

describe "Config Error - 无关错误不触发"
echo "Connection refused to remote server" > "$ERR_LOG"
assert_false "is_config_error" "无关错误 → 非 config 错误"

# 清理
rm -f "$ERR_LOG"

# ────────────────────────────────────────────────────────────────
# 7.1 退化信号检测测试（新增）
# ────────────────────────────────────────────────────────────────
describe "Degraded Signals - 无日志时返回 NONE"
rm -f "$ERR_LOG"
assert_eq "NONE" "$(check_degraded_signals)" "无错误日志 → NONE"

describe "Degraded Signals - 旧日志不触发"
echo "embedded run timeout" > "$ERR_LOG"
touch -t $(date -v-20M +%Y%m%d%H%M.%S) "$ERR_LOG"
assert_eq "NONE" "$(check_degraded_signals)" "超过时间窗口 → NONE"

describe "Degraded Signals - 最近高风险日志触发 DEGRADED"
> "$ERR_LOG"
for i in $(seq 1 9); do
    echo "FailoverError: LLM request timed out." >> "$ERR_LOG"
done
res=$(check_degraded_signals)
assert_true "[[ \"$res\" == DEGRADED:* ]]" "高风险日志计数达阈值 → DEGRADED"

describe "Degraded Signals - 最近低风险日志不触发"
> "$ERR_LOG"
for i in $(seq 1 3); do
    echo "random warning line $i" >> "$ERR_LOG"
done
assert_eq "NONE" "$(check_degraded_signals)" "低风险日志不足阈值 → NONE"

# ────────────────────────────────────────────────────────────────
# 7.2 连续异常计数测试（新增）
# ────────────────────────────────────────────────────────────────
describe "Unhealthy Streak - 初始与重置"
reset_unhealthy_streak
assert_eq "0" "$(get_unhealthy_streak)" "初始 streak 为 0"
assert_file_not_exists "$UNHEALTHY_REASON_FILE" "初始无 reason 文件"

describe "Unhealthy Streak - 递增并记录 reason"
count1=$(increment_unhealthy_streak "DEGRADED:9")
assert_eq "1" "$count1" "首次递增为 1"
assert_eq "1" "$(get_unhealthy_streak)" "streak 文件值为 1"
assert_eq "DEGRADED:9" "$(cat "$UNHEALTHY_REASON_FILE")" "reason 已写入"
count2=$(increment_unhealthy_streak "RPC_TIMEOUT")
assert_eq "2" "$count2" "二次递增为 2"
assert_eq "RPC_TIMEOUT" "$(cat "$UNHEALTHY_REASON_FILE")" "reason 更新为最新值"

describe "Unhealthy Streak - reset 后归零"
reset_unhealthy_streak
assert_eq "0" "$(get_unhealthy_streak)" "reset 后 streak 为 0"
assert_file_not_exists "$UNHEALTHY_REASON_FILE" "reset 后 reason 文件删除"

# ────────────────────────────────────────────────────────────────
# 8. JSON 合法性检查测试
# ────────────────────────────────────────────────────────────────
describe "JSON Validation - 有效 JSON"
assert_true "$PYTHON -c \"import json; json.load(open('$CONFIG_FILE'))\" 2>/dev/null" "有效 JSON 通过检查"

describe "JSON Validation - 无效 JSON"
echo "{invalid" > "$TEST_DIR/bad.json"
assert_false "$PYTHON -c \"import json; json.load(open('$TEST_DIR/bad.json'))\" 2>/dev/null" "无效 JSON 未通过检查"

describe "JSON Validation - 空文件"
echo "" > "$TEST_DIR/empty.json"
assert_false "$PYTHON -c \"import json; json.load(open('$TEST_DIR/empty.json'))\" 2>/dev/null" "空文件未通过检查"

# ────────────────────────────────────────────────────────────────
# 9. 配置备份与清理测试
# ────────────────────────────────────────────────────────────────
describe "Backup - 创建配置备份"
cp "$CONFIG_FILE" "$BACKUP_DIR/openclaw.json.test_backup_1"
assert_file_exists "$BACKUP_DIR/openclaw.json.test_backup_1" "备份文件已创建"

describe "Backup - 清理过期备份（超过 MAX_BACKUPS）"
# 创建 26 个备份（超过 MAX_BACKUPS=24）
for i in $(seq 1 26); do
    cp "$CONFIG_FILE" "$BACKUP_DIR/openclaw.json.cleanup_test_$i"
done
BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/openclaw.json.* 2>/dev/null | wc -l | tr -d ' ')
assert_true "[[ $BACKUP_COUNT -gt $MAX_BACKUPS ]]" "备份数量 ($BACKUP_COUNT) 超过限制 ($MAX_BACKUPS)"

# 执行清理逻辑
for PREFIX in openclaw.json; do
    CURRENT_COUNT=$(ls -1 "$BACKUP_DIR"/${PREFIX}.* 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$CURRENT_COUNT" -gt "$MAX_BACKUPS" ]]; then
        EXCESS=$((CURRENT_COUNT - MAX_BACKUPS))
        ls -1t "$BACKUP_DIR"/${PREFIX}.* | tail -$EXCESS | xargs rm -f
    fi
done
AFTER_COUNT=$(ls -1 "$BACKUP_DIR"/openclaw.json.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$MAX_BACKUPS" "$AFTER_COUNT" "清理后备份数量等于 MAX_BACKUPS ($MAX_BACKUPS)"

# ────────────────────────────────────────────────────────────────
# 10. 日志轮转测试
# ────────────────────────────────────────────────────────────────
describe "Log Rotation - 小日志不轮转"
# 写入 100 行
for i in $(seq 1 100); do
    echo "test log line $i" >> "$LOG_FILE"
done
LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
assert_true "[[ $LINE_COUNT -le 2000 ]]" "100 行日志不需要轮转"

describe "Log Rotation - 超过 2000 行触发轮转"
# 写入 2500 行
> "$LOG_FILE"
for i in $(seq 1 2500); do
    echo "test log line $i" >> "$LOG_FILE"
done
LINE_COUNT=$(wc -l < "$LOG_FILE" | tr -d ' ')
assert_true "[[ $LINE_COUNT -gt 2000 ]]" "日志超过 2000 行 ($LINE_COUNT)"

# 执行轮转
if [[ "$LINE_COUNT" -gt 2000 ]]; then
    tail -1000 "$LOG_FILE" > "$LOG_FILE.tmp"
    mv "$LOG_FILE.tmp" "$LOG_FILE"
fi
AFTER_LINES=$(wc -l < "$LOG_FILE" | tr -d ' ')
assert_eq "1000" "$AFTER_LINES" "轮转后保留 1000 行"

# ────────────────────────────────────────────────────────────────
# 11. 关键配置字段检查测试
# ────────────────────────────────────────────────────────────────
describe "Config Fields - Agent 数量检查"
AGENT_COUNT=$($PYTHON -c "import json; d=json.load(open('$CONFIG_FILE')); print(len(d.get('agents',{}).get('list',[])))" 2>/dev/null)
assert_true "[[ $AGENT_COUNT -ge 3 ]]" "Agent 数量 ($AGENT_COUNT) >= 3"

describe "Config Fields - Agent 数量过少告警"
echo '{"agents":{"list":[{"name":"a"}]}}' > "$TEST_DIR/few_agents.json"
FEW_COUNT=$($PYTHON -c "import json; d=json.load(open('$TEST_DIR/few_agents.json')); print(len(d.get('agents',{}).get('list',[])))" 2>/dev/null)
assert_true "[[ $FEW_COUNT -lt 3 ]]" "Agent 数量 ($FEW_COUNT) < 3 触发告警"

describe "Config Fields - Gateway 端口检查"
GATEWAY_PORT_CFG=$($PYTHON -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('gateway',{}).get('port',''))" 2>/dev/null)
assert_eq "18789" "$GATEWAY_PORT_CFG" "Gateway 端口为 18789"

# ────────────────────────────────────────────────────────────────
# 12. 集成测试：配置损坏 → 自动恢复流程
# ────────────────────────────────────────────────────────────────
describe "Integration - 配置损坏 → LKG 恢复完整流程"
# 确保有 LKG
save_last_known_good
# 破坏配置
echo "CORRUPTED {{{" > "$CONFIG_FILE"
# 检测 JSON 无效
CONFIG_VALID=0
if $PYTHON -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
    CONFIG_VALID=1
fi
assert_eq "0" "$CONFIG_VALID" "损坏的配置被检测为无效"
# 执行恢复
if restore_last_known_good; then
    CONFIG_VALID=1
fi
assert_eq "1" "$CONFIG_VALID" "从 LKG 恢复后配置有效"
assert_true "$PYTHON -c \"import json; json.load(open('$CONFIG_FILE'))\" 2>/dev/null" "恢复后 JSON 合法"

describe "Integration - 配置损坏 → 无 LKG → auto backup 恢复"
# 恢复有效配置并创建 auto backup
cat > "$CONFIG_FILE" << 'TESTJSON'
{"agents":{"list":[{"name":"a1"},{"name":"a2"},{"name":"a3"}]},"gateway":{"port":18789}}
TESTJSON
cp "$CONFIG_FILE" "$BACKUP_DIR/openclaw.json.integration_test"
# 删除 LKG
rm -f "$LAST_KNOWN_GOOD_DIR/openclaw.json"
# 破坏配置
echo "BROKEN AGAIN" > "$CONFIG_FILE"
# LKG 恢复失败
assert_false "restore_last_known_good" "无 LKG → 恢复失败"
# 从 auto backup 恢复
LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/openclaw.json.* 2>/dev/null | head -1)
assert_true "[[ -n '$LATEST_BACKUP' ]]" "找到 auto backup"
if [[ -n "$LATEST_BACKUP" ]] && $PYTHON -c "import json; json.load(open('$LATEST_BACKUP'))" 2>/dev/null; then
    cp "$LATEST_BACKUP" "$CONFIG_FILE"
fi
assert_true "$PYTHON -c \"import json; json.load(open('$CONFIG_FILE'))\" 2>/dev/null" "从 auto backup 恢复后 JSON 合法"

# ────────────────────────────────────────────────────────────────
# 13. 集成测试：指数退避 + cooldown 联动
# ────────────────────────────────────────────────────────────────
describe "Integration - 指数退避与 cooldown 联动"
reset_crash_count
rm -f "$COOLDOWN_FILE"
# 模拟第一次 crash
increment_crash_count
set_last_restart
assert_true "is_in_cooldown" "第 1 次 crash 后在 cooldown 中 (需等 60s)"
# 模拟 cooldown 过期
echo $(( $(date +%s) - 70 )) > "$COOLDOWN_FILE"
assert_false "is_in_cooldown" "60s 后 cooldown 过期"
# 第二次 crash，backoff 增加
increment_crash_count
set_last_restart
backoff=$(get_backoff_delay)
assert_eq "120" "$backoff" "第 2 次 crash backoff 为 120s"

# 清理
reset_crash_count
rm -f "$COOLDOWN_FILE"

# ────────────────────────────────────────────────────────────────
# 14. 集成测试：doctor --fix 耗尽 → LKG 回滚
# ────────────────────────────────────────────────────────────────
describe "Integration - doctor --fix 耗尽后触发 LKG 回滚"
reset_doctor_fix_counter
# 恢复有效配置和 LKG
cat > "$CONFIG_FILE" << 'TESTJSON'
{"agents":{"list":[{"name":"a1"},{"name":"a2"},{"name":"a3"}]},"gateway":{"port":18789}}
TESTJSON
save_last_known_good
# 用完 doctor --fix 次数
assert_true "try_doctor_fix" "第 1 次 doctor --fix"
assert_true "try_doctor_fix" "第 2 次 doctor --fix"
assert_false "try_doctor_fix" "第 3 次被拒绝"
# 此时应触发 LKG 回滚
fix_count=$(cat "$DOCTOR_FIX_COUNTER_FILE")
assert_true "[[ $fix_count -ge $MAX_DOCTOR_FIX ]]" "fix_count ($fix_count) >= MAX ($MAX_DOCTOR_FIX)"
# 破坏配置后恢复
echo "BAD CONFIG" > "$CONFIG_FILE"
assert_true "restore_last_known_good" "doctor --fix 耗尽后 LKG 回滚成功"

# 清理
reset_doctor_fix_counter

# ────────────────────────────────────────────────────────────────
# 15. Cron 配置恢复测试
# ────────────────────────────────────────────────────────────────
describe "Cron - 有效 cron 配置通过检查"
assert_true "$PYTHON -c \"import json; json.load(open('$CRON_FILE'))\" 2>/dev/null" "cron/jobs.json 是有效 JSON"

describe "Cron - 损坏的 cron 配置从备份恢复"
cp "$CRON_FILE" "$BACKUP_DIR/jobs.json.cron_test"
echo "BROKEN CRON" > "$CRON_FILE"
assert_false "$PYTHON -c \"import json; json.load(open('$CRON_FILE'))\" 2>/dev/null" "损坏的 cron 被检测为无效"
LATEST_CRON_BACKUP=$(ls -t "$BACKUP_DIR"/jobs.json.* 2>/dev/null | head -1)
if [[ -n "$LATEST_CRON_BACKUP" ]] && $PYTHON -c "import json; json.load(open('$LATEST_CRON_BACKUP'))" 2>/dev/null; then
    cp "$LATEST_CRON_BACKUP" "$CRON_FILE"
fi
assert_true "$PYTHON -c \"import json; json.load(open('$CRON_FILE'))\" 2>/dev/null" "从备份恢复后 cron 有效"

# ============================================================================
# 测试结果汇总
# ============================================================================
echo -e "\n${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}  全部通过！ $TESTS_PASSED/$TESTS_RUN 测试通过${NC}"
else
    echo -e "${RED}  $TESTS_FAILED 个测试失败！ $TESTS_PASSED/$TESTS_RUN 测试通过${NC}"
fi
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"

# 清理测试目录
rm -rf "$TEST_DIR"

exit $TESTS_FAILED
