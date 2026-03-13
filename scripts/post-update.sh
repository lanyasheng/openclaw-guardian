#!/bin/bash
# OpenClaw 更新后的一键修复脚本
# 用法: bash ~/.openclaw/scripts/post-update.sh

export PATH=/Users/study/.npm-global/bin:/opt/homebrew/bin:$PATH
PYTHON=/opt/homebrew/bin/python3.12

echo "=== OpenClaw Post-Update Script ==="
echo "Version: $(openclaw --version 2>/dev/null || echo unknown)"

# 1. Restart gateway first (so CLI can connect)
echo "[1/3] Restarting gateway..."
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway 2>&1
sleep 5
pgrep -f openclaw-gateway > /dev/null && echo "  Gateway restarted" || { echo "  ERROR: Gateway not running"; exit 1; }

# 2. Get token
TOKEN=$($PYTHON -c "import json; f=open('/Users/study/.openclaw/openclaw.json'); d=json.load(f); print(d['gateway']['auth']['token'])")

# 3. Set timeouts via CLI (persistent, won't be overwritten by gateway)
echo "[2/3] Setting timeouts via CLI..."

set_timeout() {
    openclaw cron edit "$1" --timeout-seconds "$2" --token "$TOKEN" > /dev/null 2>&1 && echo "  $3 -> ${2}s" || echo "  WARN: $3 failed"
}

set_timeout "4388e835-4a1f-4f26-a5ab-7a15dc641b90" 300 "trading-closing-summary"
set_timeout "cd4850cc-be9d-45c7-8cbc-b49fface12cc" 300 "trading-weekly-review"
set_timeout "79fab23a-d91e-4d25-911f-9c6f922ec7ee" 240 "ainews-evening-report"
set_timeout "f28287d3-0070-474b-a90d-99424eae44ec" 240 "trading-weekly-tech-review"
set_timeout "951508ce-80e5-4606-acda-4e552b368eb4" 300 "ainews-weekly-review"
set_timeout "83c9d11c-d898-4a24-8bac-675c35639f82" 180 "ainews-daily-ops-summary"
set_timeout "a9b78a29-5ed4-4c34-8fef-c055f947e729" 180 "daily-reflection-trading"
set_timeout "fb157521-a96a-4c50-8508-1fab6a11634f" 180 "daily-reflection-ainews"
set_timeout "2e37668c-f5ba-4a7c-b8b6-4dbd3d6cd8d5" 180 "daily-reflection-main"
set_timeout "5d94a448-f3bd-4252-816b-e51ad125488a" 180 "daily-reflection-macro"
set_timeout "2d14433f-cc5d-4858-b4e1-3e8404b9e723" 240 "macro-daily-check"
set_timeout "30ddf969-d1c0-482a-8278-03e30cc2b222" 180 "trading-daily-archive"
set_timeout "b524d2e9-391e-486f-89b7-fdf3624d748f" 240 "ainews-paper-digest"
set_timeout "809cb3b3-abfe-4a55-9d62-59be4701ff52" 180 "finance-news-evening"
set_timeout "72744441-21f5-44bf-b6e5-bb9a6cc4ecca" 180 "trading-opening-bell"
set_timeout "123f0d57-9f58-46c3-9d73-275e7ffd1c69" 180 "trading-morning-brief"

# 4. Fix delivery configs (bestEffort + hint)
echo "[3/4] Fixing delivery hints..."
$PYTHON << "PYEOF"
import json

JOBS_FILE = "/Users/study/.openclaw/cron/jobs.json"
HINT = "直接以文本回复输出报告内容，系统会自动投递到 Discord，不要自己调用 message 工具。"

with open(JOBS_FILE) as f:
    data = json.load(f)

count = 0
for j in data.get("jobs", []):
    d = j.get("delivery", {})
    if d.get("mode") == "announce":
        if not d.get("bestEffort"):
            d["bestEffort"] = True
            j["delivery"] = d
            count += 1
        msg = j.get("payload", {}).get("message", "")
        if msg and "不要自己调用 message 工具" not in msg:
            j["payload"]["message"] = msg.rstrip() + "\n\n" + HINT
            count += 1

with open(JOBS_FILE, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print(f"  Fixed {count} delivery hints")
PYEOF

# 5. Set exec approvals (auto-approve scripts for all agents)
echo "[4/4] Setting exec approvals..."
openclaw approvals allowlist add --agent "*" --token "$TOKEN" "/opt/homebrew/bin/python3.12*" > /dev/null 2>&1
openclaw approvals allowlist add --agent "*" --token "$TOKEN" "~/.openclaw/workspace-*/skills/*/scripts/*" > /dev/null 2>&1
openclaw approvals allowlist add --agent "*" --token "$TOKEN" "bash ~/.openclaw/workspace-*/skills/*/scripts/*" > /dev/null 2>&1
openclaw approvals allowlist add --agent "*" --token "$TOKEN" "cat ~/.openclaw/*" > /dev/null 2>&1
openclaw approvals allowlist add --agent "*" --token "$TOKEN" "cat /tmp/*" > /dev/null 2>&1
echo "  Exec approvals set for all agents"

echo "=== Done ==="
