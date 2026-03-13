<p align="center">
  <h1 align="center">OpenClaw Guardian</h1>
  <p align="center">
    Three-layer self-healing system for OpenClaw Gateway<br/>
    OpenClaw 网关三层自愈系统
  </p>
</p>

<p align="center">
  <a href="#quick-start--快速开始">Quick Start</a> •
  <a href="#architecture--架构">Architecture</a> •
  <a href="#scripts--脚本说明">Scripts</a> •
  <a href="#configuration--配置">Configuration</a> •
  <a href="#testing--测试">Testing</a>
</p>

---

## What is this / 这是什么

Running multiple AI agents 24/7 with [OpenClaw](https://github.com/nicepkg/openclaw) is straightforward — until things break at 3 AM. macOS `launchd` restarts crashed processes, but it can't detect a gateway that's alive yet unresponsive, fix a corrupted config, or clean up orphaned child processes eating all your RAM.

This project fills those gaps with a battle-tested, cron-based monitoring system. It has automatically recovered from 40+ incidents over half a month of continuous operation with 6 agents.

用 [OpenClaw](https://github.com/nicepkg/openclaw) 跑 6 个 AI Agent 全天候运行很简单——直到凌晨 3 点出事。macOS 的 `launchd` 只管进程是否存活，无法检测网关"假活"、修复被 Agent 改坏的配置、或清理吃光内存的孤儿进程。

本项目用 cron 定时任务实现了经过实战检验的自愈系统。半个月内自动恢复了 40 多次故障，覆盖 6 个 Agent 的全天候运行。

> **Blog post / 详细踩坑经历**: [OpenClaw 7×24 生存指南](https://mp.weixin.qq.com/s/xxx) *(coming soon)*

## Architecture / 架构

Three layers, each with a clear responsibility:

三层架构，各司其职：

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| **L1 System** | macOS `launchd` | Process dies → restart within 30s |
| **L2 Application** | `heartbeat-guardian.sh` | Health checks → smart repair → config rollback → orphan cleanup → OOM protection |
| **L3 Data** | Maintenance scripts | Memory compaction, cron health, Chrome repair, upgrade protection |

| 层级 | 组件 | 职责 |
|------|------|------|
| **L1 系统级** | macOS `launchd` | 进程挂了 → 30s 内拉起 |
| **L2 应用级** | `heartbeat-guardian.sh` | 健康检查 → 智能修复 → 配置回滚 → 孤儿清理 → OOM 保护 |
| **L3 数据级** | 维护脚本群 | 记忆压缩 / Cron 健康 / Chrome 修复 / 升级保护 |

**Key design decision**: All monitoring runs via system crontab, completely independent of the OpenClaw Gateway. The guardian never depends on the thing it guards.

**核心设计决策**：所有运维脚本跑在系统 crontab 上，完全不依赖 OpenClaw Gateway。守护者绝不依赖被守护的对象。

## Quick Start / 快速开始

### Prerequisites / 前置要求

- macOS with `launchd` (recommended) or any Unix with cron
- [OpenClaw](https://github.com/nicepkg/openclaw) installed and configured
- Bash 4+ and Python 3.9+

### Install / 安装

```bash
git clone https://github.com/lanyasheng/openclaw-guardian.git
cd openclaw-guardian

# Copy scripts to OpenClaw directory
cp scripts/heartbeat-guardian.sh ~/.openclaw/scripts/
cp scripts/memory_maintenance.py ~/.openclaw/scripts/
cp scripts/check_cron_health.py ~/.openclaw/scripts/
cp scripts/post-update.sh ~/.openclaw/scripts/
cp scripts/upgrade-openclaw.sh ~/.openclaw/scripts/
chmod +x ~/.openclaw/scripts/*.sh
```

### Configure crontab / 配置定时任务

```bash
crontab -e
```

Add the following entries / 添加以下条目：

```cron
# L2 Heartbeat — every 5 minutes / 每 5 分钟
*/5 * * * * /bin/bash ~/.openclaw/scripts/heartbeat-guardian.sh

# L3 Memory maintenance — every Sunday 4 AM / 每周日凌晨 4 点
0 4 * * 0 python3 ~/.openclaw/scripts/memory_maintenance.py --all --broadcast

# L3 Cron health — every 30 minutes / 每 30 分钟
*/30 * * * * python3 ~/.openclaw/scripts/check_cron_health.py
```

### Verify / 验证

```bash
# Dry run (no actual repairs)
bash ~/.openclaw/scripts/heartbeat-guardian.sh --dry-run

# Run tests
bash tests/test-guardian.sh
```

## Scripts / 脚本说明

| Script | Lines | Purpose |
|--------|-------|---------|
| `heartbeat-guardian.sh` | 800+ | **Core**. Step 0 system protection (orphan/OOM) → Step 0.5 log rotation + Chrome cleanup → HTTP+RPC health check → config repair → exponential backoff restart |
| `test-guardian.sh` | 700+ | 47 unit tests + 5 integration tests |
| `memory_maintenance.py` | 500+ | MEMORY.md compaction + daily memory archival + learnings cleanup |
| `check_cron_health.py` | 120+ | Critical cron task status check + Chrome CDP self-repair |
| `post-update.sh` | 80+ | Post-upgrade restart + cron timeout recovery + delivery fix |
| `upgrade-openclaw.sh` | ~50 | Upgrade entrypoint, auto-invokes post-update |

| 脚本 | 行数 | 作用 |
|------|------|------|
| `heartbeat-guardian.sh` | 800+ | **核心**。Step 0 系统保护(孤儿/OOM) → Step 0.5 日志轮转+Chrome清理 → HTTP+RPC 健康检查 → 配置修复 → 指数退避重启 |
| `test-guardian.sh` | 700+ | 47 个单元测试 + 5 个集成测试 |
| `memory_maintenance.py` | 500+ | MEMORY.md 压缩 + daily memory 归档 + learnings 清理 |
| `check_cron_health.py` | 120+ | 关键 cron 任务状态检查 + Chrome CDP 自修复 |
| `post-update.sh` | 80+ | 升级后重启 + 恢复 cron timeout + 修复 delivery |
| `upgrade-openclaw.sh` | ~50 | 升级入口，自动调用 post-update |

## Configuration / 配置

Edit the variables at the top of `heartbeat-guardian.sh`:

编辑 `heartbeat-guardian.sh` 顶部的配置区：

```bash
GATEWAY_PORT=18789                         # Gateway HTTP port
HEALTH_TIMEOUT=5                           # HTTP health check timeout (seconds)
RPC_HEALTH_TIMEOUT=8                       # RPC health check timeout (seconds)
DEGRADED_ERROR_THRESHOLD=15                # Severe error threshold in err.log
DEGRADED_CONSECUTIVE_THRESHOLD=3           # Consecutive DEGRADED count before restart
MAX_TOTAL_RETRIES=6                        # Maximum retry count
CRASH_DECAY_HOURS=6                        # Fault counter auto-decay interval
BACKOFF_DELAYS=(60 120 300 600 900 1800)   # Exponential backoff (seconds)
ACTIVE_HOURS_START="08:00"                 # Active hours start (DEGRADED won't trigger restart)
ACTIVE_HOURS_END="23:00"                   # Active hours end
```

## What it handles / 能处理的问题

Problems this system has handled in production:

以下是生产环境中实际处理过的问题：

1. **Agent corrupts config** → Gateway boot loop → auto config rollback
2. **API quota exhausted** → model fallback inconsistency across 4 priority layers
3. **Session bloat** → agent context degradation
4. **Chrome `SingletonLock` / Renderer pile-up** → browser automation failure
5. **Guardian itself destabilizing Gateway** → overly aggressive health checks
6. **ACP child process orphan accumulation → OOM → macOS system crash** (OpenClaw Bug #35886)
7. **SOCKS proxy interfering with localhost health checks** → false negative detection
8. **Overly strict DEGRADED thresholds** → normal operational noise triggering unnecessary restarts
9. **Chrome orphan processes consuming 10GB+ RAM** → gradual memory exhaustion
10. **Log files growing unbounded** → disk space exhaustion

## Testing / 测试

```bash
# Run all 47 tests
bash tests/test-guardian.sh

# Example output:
# ✓ crash counter starts at 0
# ✓ crash counter increments
# ...
# Results: 47 passed, 0 failed, 0 skipped
```

## License

MIT
