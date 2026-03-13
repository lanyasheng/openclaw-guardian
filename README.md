# openclaw-guardian

OpenClaw Gateway 的三层自愈系统。6 个 AI Agent 7×24 全天候运行，自动恢复了 40 多次，手动修了 3 次。

> 详细踩坑经历和设计思路见 [OpenClaw 7×24 生存指南](./docs/article.md)

## 这是什么

跑 OpenClaw 多 Agent 系统时，Gateway 会因为各种原因挂掉：配置被 Agent 改坏了、ACP 子进程泄漏导致 OOM、API 额度耗尽、Chrome 僵死... macOS 自带的 launchd 只管进程活着，不管业务健不健康。这套脚本补上了缺失的部分。

## 架构

三层，各司其职：

| 层级 | 组件 | 职责 |
|------|------|------|
| **L1 系统级** | macOS launchd | 进程挂了 → 30s 拉起 |
| **L2 应用级** | heartbeat-guardian.sh | HTTP+RPC 健康检查 → 智能修复 → 配置回滚 → 孤儿清理 → OOM 保护 |
| **L3 数据级** | 维护脚本群 | 记忆压缩 / Cron 健康 / Chrome 修复 / 升级保护 |

**核心决策：运维脚本跑在系统 crontab 上，不依赖 OpenClaw Gateway。**

## 快速开始

### 1. 安装

```bash
git clone https://github.com/your-username/openclaw-guardian.git
cd openclaw-guardian

# 复制脚本到 OpenClaw 目录
cp scripts/heartbeat-guardian.sh ~/.openclaw/scripts/
cp scripts/memory_maintenance.py ~/.openclaw/scripts/
cp scripts/check_cron_health.py ~/.openclaw/scripts/
cp scripts/post-update.sh ~/.openclaw/scripts/
cp scripts/upgrade-openclaw.sh ~/.openclaw/scripts/
chmod +x ~/.openclaw/scripts/*.sh
```

### 2. 配置 crontab

```bash
crontab -e
```

添加：

```bash
# L2 心跳 — 每 5 分钟
*/5 * * * * /bin/bash ~/.openclaw/scripts/heartbeat-guardian.sh

# L3 记忆维护 — 每周日凌晨 4 点
0 4 * * 0 python3 ~/.openclaw/scripts/memory_maintenance.py --all --broadcast

# L3 日报同步 — 每天 21:45（可选）
# 45 21 * * * /bin/bash ~/.openclaw/scripts/daily-reports-sync.sh
```

### 3. 验证

```bash
# Dry run（不执行修复）
bash ~/.openclaw/scripts/heartbeat-guardian.sh --dry-run

# 运行测试
bash tests/test-guardian.sh
```

## 脚本说明

| 脚本 | 行数 | 作用 |
|------|------|------|
| `heartbeat-guardian.sh` | 600+ | **核心**。Step 0 系统保护(孤儿/OOM) → HTTP+RPC 健康检查 → 配置修复 → 指数退避重启 |
| `test-guardian.sh` | 700+ | 47 个单元测试 + 5 个集成测试 |
| `memory_maintenance.py` | 500+ | MEMORY.md 压缩 + daily memory 归档 + learnings 清理 |
| `check_cron_health.py` | 120+ | 关键 cron 任务状态检查 + Chrome CDP 自修复 |
| `post-update.sh` | 80+ | 升级后重启 + 恢复 cron timeout + 修复 delivery |
| `upgrade-openclaw.sh` | ~50 | 升级入口，自动调用 post-update |
| `switch_model.py` | ~200 | 全层级模型切换（全局→per-agent→cron→session） |

## 处理过的问题

1. Agent 改坏配置 → Gateway 起不来 → 无限重启
2. API 额度耗尽 → 模型配置 4 层优先级不一致
3. Session 膨胀 → Agent 变笨
4. Chrome SingletonLock / Renderer 堆积
5. 运维脚本自己把 Gateway 搞挂（检查太频繁）
6. **ACP 子进程孤儿累积 → OOM → macOS 系统崩溃**（Bug #35886）
7. **SOCKS 代理干扰 localhost 健康检查**
8. **DEGRADED 阈值过严 → 正常业务行为被当成故障**

## 配置

`heartbeat-guardian.sh` 顶部的配置区块：

```bash
GATEWAY_PORT=18789           # Gateway HTTP 端口
HEALTH_TIMEOUT=5             # HTTP 健康检查超时(秒)
RPC_HEALTH_TIMEOUT=8         # RPC 健康检查超时(秒)
DEGRADED_ERROR_THRESHOLD=15  # err.log 严重错误阈值
DEGRADED_CONSECUTIVE_THRESHOLD=3  # 连续 DEGRADED 次数
MAX_TOTAL_RETRIES=6          # 最大重试次数
CRASH_DECAY_HOURS=6          # 故障计数器自动衰减时间
BACKOFF_DELAYS=(60 120 300 600 900 1800)  # 指数退避(秒)
ACTIVE_HOURS_START="08:00"   # 活跃时段(DEGRADED 不重启)
ACTIVE_HOURS_END="23:00"
```

## 测试

```bash
# 运行全部 47 个测试
bash tests/test-guardian.sh

# 输出示例:
# ✓ crash counter starts at 0
# ✓ crash counter increments
# ...
# Results: 47 passed, 0 failed, 0 skipped
```

## License

MIT
