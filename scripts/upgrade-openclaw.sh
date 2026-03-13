#!/bin/bash
# OpenClaw 一键升级脚本
# 用法: bash ~/.openclaw/scripts/upgrade-openclaw.sh
#
# 替代直接运行 npm update -g openclaw
# 自动执行: 升级 → 修复配置 → 重启

set -e

echo "=== OpenClaw 升级 ==="

# 保存当前版本
OLD_VER=$(/Users/study/.npm-global/bin/openclaw --version 2>/dev/null || echo "unknown")
echo "当前版本: $OLD_VER"

# 升级
echo "[1/3] 升级 OpenClaw..."
export PATH="/opt/homebrew/bin:$PATH"
npm update -g openclaw

# 检查新版本
NEW_VER=$(/Users/study/.npm-global/bin/openclaw --version 2>/dev/null || echo "unknown")
echo "新版本: $NEW_VER"

if [ "$OLD_VER" = "$NEW_VER" ]; then
    echo "版本未变化，跳过修复"
    exit 0
fi

# 修复配置
echo "[2/3] 修复配置..."
bash /Users/study/.openclaw/scripts/post-update.sh

echo "[3/3] 完成！$OLD_VER → $NEW_VER"
