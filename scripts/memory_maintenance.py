#!/usr/bin/env python3
"""
Memory Maintenance Script for OpenClaw Agents.

Prevents unbounded growth of MEMORY.md, LEARNINGS.md, and daily memory files.

Runs as a cron job (weekly recommended):
  0 4 * * 0  python3 ~/.openclaw/scripts/memory_maintenance.py --all

Design:
  - MEMORY.md: sections with dates older than 30 days archived to memory/archive/
  - LEARNINGS.md: promoted entries removed (already in MEMORY.md)
  - memory/*.md: files older than 14 days moved to memory/archive/
  - knowledge/daily/: directories older than 30 days moved to knowledge/archive/
"""

import argparse
import json
import os
import re
import shutil
from datetime import datetime, timedelta
from pathlib import Path


AGENT_WORKSPACES = {
    "main": "~/.openclaw/workspace",
    "trading": "~/.openclaw/workspace-trading",
    "ainews": "~/.openclaw/workspace-ainews",
    "macro": "~/.openclaw/workspace-macro",
    "butler": "~/.openclaw/workspace-butler",
    "content": "~/.openclaw/workspace-content",
}

MEMORY_MAX_LINES = 200
MEMORY_KEEP_LINES = 150
LEARNINGS_MAX_ENTRIES = 30
DAILY_MEMORY_KEEP_DAYS = 14
KNOWLEDGE_DAILY_KEEP_DAYS = 30

MEMORY_PERMANENT_SECTIONS = frozenset([
    "团队架构",
    "team architecture",
    "core identity",
    "核心身份",
    "待办事项",
    "todo",
])


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}")


def ensure_archive_dir(base_dir: str, subdir: str = "archive") -> Path:
    archive = Path(base_dir) / subdir
    archive.mkdir(parents=True, exist_ok=True)
    return archive


def archive_old_daily_memory(workspace: str, agent: str, keep_days: int = DAILY_MEMORY_KEEP_DAYS) -> int:
    """Move daily memory files older than keep_days to archive."""
    memory_dir = Path(workspace) / "memory"
    if not memory_dir.exists():
        return 0

    cutoff = datetime.now() - timedelta(days=keep_days)
    archived = 0
    archive_dir = ensure_archive_dir(str(memory_dir))

    for f in memory_dir.glob("*.md"):
        match = re.match(r"(\d{4}-\d{2}-\d{2})", f.name)
        if not match:
            continue
        try:
            file_date = datetime.strptime(match.group(1), "%Y-%m-%d")
            if file_date < cutoff:
                dest = archive_dir / f.name
                shutil.move(str(f), str(dest))
                log(f"  [{agent}] Archived daily memory: {f.name}")
                archived += 1
        except ValueError:
            continue

    return archived


def archive_old_knowledge_daily(workspace: str, agent: str, keep_days: int = KNOWLEDGE_DAILY_KEEP_DAYS) -> int:
    """Move old knowledge/daily/ subdirectories to archive."""
    daily_dir = Path(workspace) / "knowledge" / "daily"
    if not daily_dir.exists():
        return 0

    cutoff = datetime.now() - timedelta(days=keep_days)
    archived = 0
    archive_dir = ensure_archive_dir(str(daily_dir), "archive")

    for d in daily_dir.iterdir():
        if not d.is_dir() or d.name == "archive":
            continue
        match = re.match(r"(\d{4}-\d{2}-\d{2})", d.name)
        if not match:
            continue
        try:
            dir_date = datetime.strptime(match.group(1), "%Y-%m-%d")
            if dir_date < cutoff:
                dest = archive_dir / d.name
                shutil.move(str(d), str(dest))
                log(f"  [{agent}] Archived knowledge/daily: {d.name}")
                archived += 1
        except ValueError:
            continue

    return archived


def clean_promoted_learnings(workspace: str, agent: str) -> int:
    """Remove promoted entries from LEARNINGS.md (already in MEMORY.md)."""
    learnings_path = Path(workspace) / ".learnings" / "LEARNINGS.md"
    if not learnings_path.exists():
        return 0

    content = learnings_path.read_text(encoding="utf-8")
    lines = content.split("\n")

    new_lines = []
    removed = 0

    i = 0
    while i < len(lines):
        line = lines[i]

        if line.startswith("## [LRN-"):
            block_lines = [line]
            i += 1
            while i < len(lines) and not lines[i].startswith("## [LRN-"):
                block_lines.append(lines[i])
                i += 1

            block_text = "\n".join(block_lines)
            if "**Status**: promoted" in block_text or "Status: promoted" in block_text:
                removed += 1
                log(f"  [{agent}] Removed promoted learning: {block_lines[0][:60]}")
                continue
            else:
                new_lines.extend(block_lines)
        else:
            new_lines.append(line)
            i += 1

    if removed > 0:
        archive_dir = ensure_archive_dir(str(learnings_path.parent), "archive")
        timestamp = datetime.now().strftime("%Y%m%d")
        archive_path = archive_dir / f"LEARNINGS_promoted_{timestamp}.md"
        shutil.copy2(str(learnings_path), str(archive_path))

        learnings_path.write_text("\n".join(new_lines), encoding="utf-8")
        log(f"  [{agent}] Backed up and cleaned {removed} promoted entries")

    return removed


def _is_permanent_section(heading: str) -> bool:
    """Check if a section heading is permanent (should never be archived)."""
    heading_lower = heading.lower().strip("# ").strip()
    for perm in MEMORY_PERMANENT_SECTIONS:
        if perm in heading_lower:
            return True
    return False


def _extract_date_from_section(section_text: str) -> str | None:
    """Extract date from section heading or content. Returns YYYY-MM-DD or None."""
    patterns = [
        r"\((\d{4}-\d{2}-\d{2})\)",
        r"\((\d{4}\.\d{2}\.\d{2})\)",
        r"(\d{4}-\d{2}-\d{2})",
    ]
    for pattern in patterns:
        match = re.search(pattern, section_text[:200])
        if match:
            date_str = match.group(1).replace(".", "-")
            try:
                datetime.strptime(date_str, "%Y-%m-%d")
                return date_str
            except ValueError:
                continue
    return None


def compact_memory(workspace: str, agent: str, max_lines: int = MEMORY_MAX_LINES, keep_lines: int = MEMORY_KEEP_LINES) -> dict:
    """Archive old sections from MEMORY.md when it exceeds max_lines."""
    memory_path = Path(workspace) / "MEMORY.md"
    if not memory_path.exists():
        return {"lines": 0, "bytes": 0, "warning": False, "archived_sections": 0}

    content = memory_path.read_text(encoding="utf-8")
    lines = content.split("\n")
    total_lines = len(lines)

    result = {
        "lines": total_lines,
        "bytes": len(content.encode("utf-8")),
        "warning": total_lines > max_lines,
        "archived_sections": 0,
    }

    if total_lines <= max_lines:
        return result

    log(f"  [{agent}] MEMORY.md is {total_lines} lines (>{max_lines}), compacting...")

    sections = []
    current_section = {"heading": "", "lines": [], "start": 0, "permanent": True, "date": None}

    for i, line in enumerate(lines):
        if re.match(r"^##\s+", line):
            if current_section["lines"]:
                sections.append(current_section)
            is_perm = _is_permanent_section(line)
            current_section = {
                "heading": line,
                "lines": [line],
                "start": i,
                "permanent": is_perm,
                "date": _extract_date_from_section(line),
            }
        else:
            current_section["lines"].append(line)

    if current_section["lines"]:
        sections.append(current_section)

    cutoff = (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d")
    archivable = []
    keep = []

    for section in sections:
        if section["permanent"]:
            keep.append(section)
        elif section["date"] and section["date"] < cutoff:
            archivable.append(section)
        else:
            keep.append(section)

    if not archivable:
        log(f"  [{agent}] No archivable sections found (all permanent or recent)")
        return result

    archive_dir = ensure_archive_dir(str(Path(workspace) / "memory"))
    timestamp = datetime.now().strftime("%Y%m%d")
    archive_path = archive_dir / f"MEMORY_archived_{timestamp}.md"

    archived_content = f"# MEMORY.md Archived Sections ({timestamp})\n\n"
    archived_content += f"> Archived {len(archivable)} sections from {agent} MEMORY.md\n"
    archived_content += f"> Cutoff date: {cutoff}\n\n---\n\n"

    for section in archivable:
        archived_content += "\n".join(section["lines"]) + "\n\n"

    archive_path.write_text(archived_content, encoding="utf-8")

    new_lines = []
    for section in keep:
        new_lines.extend(section["lines"])

    shutil.copy2(str(memory_path), str(memory_path.with_suffix(".md.bak")))

    archive_index_lines = [
        "",
        "---",
        "",
        "## Archived Memory Index",
        "",
        "> Older entries archived to memory/archive/. Use `openclaw memory search` to find them.",
        "",
    ]
    for section in archivable:
        heading = section["heading"].strip("# ").strip()
        date = section["date"] or "unknown"
        archive_index_lines.append(f"- [{date}] {heading}")

    existing_text = "\n".join(new_lines)
    if "## Archived Memory Index" in existing_text:
        existing_text = re.sub(
            r"\n---\n\n## Archived Memory Index.*",
            "",
            existing_text,
            flags=re.DOTALL,
        )
        new_lines = existing_text.split("\n")

    new_lines.extend(archive_index_lines)

    memory_path.write_text("\n".join(new_lines), encoding="utf-8")

    new_total = len(new_lines)
    result["archived_sections"] = len(archivable)
    result["lines"] = new_total
    result["bytes"] = len("\n".join(new_lines).encode("utf-8"))
    result["warning"] = new_total > max_lines

    log(f"  [{agent}] Archived {len(archivable)} sections to {archive_path.name}")
    log(f"  [{agent}] MEMORY.md: {total_lines} → {new_total} lines")

    return result


def run_maintenance(agents: list, dry_run: bool = False) -> dict:
    """Run maintenance for specified agents."""
    results = {}

    for agent in agents:
        workspace_raw = AGENT_WORKSPACES.get(agent)
        if not workspace_raw:
            log(f"Unknown agent: {agent}")
            continue

        workspace = os.path.expanduser(workspace_raw)
        if not os.path.exists(workspace):
            log(f"Workspace not found for {agent}: {workspace}")
            continue

        log(f"Processing {agent}...")
        result = {
            "daily_memory_archived": 0,
            "knowledge_daily_archived": 0,
            "learnings_promoted_cleaned": 0,
            "memory_status": {},
        }

        if not dry_run:
            result["daily_memory_archived"] = archive_old_daily_memory(workspace, agent)
            result["knowledge_daily_archived"] = archive_old_knowledge_daily(workspace, agent)
            result["learnings_promoted_cleaned"] = clean_promoted_learnings(workspace, agent)
            result["memory_status"] = compact_memory(workspace, agent)
        else:
            memory_path = Path(workspace) / "MEMORY.md"
            if memory_path.exists():
                content = memory_path.read_text(encoding="utf-8")
                line_count = len(content.split("\n"))
                result["memory_status"] = {
                    "lines": line_count,
                    "bytes": len(content.encode("utf-8")),
                    "warning": line_count > MEMORY_MAX_LINES,
                    "archived_sections": 0,
                }
                if line_count > MEMORY_MAX_LINES:
                    log(f"  [{agent}] WARNING: MEMORY.md is {line_count} lines - would compact")
            else:
                result["memory_status"] = {"lines": 0, "bytes": 0, "warning": False, "archived_sections": 0}

        results[agent] = result

    return results


def _find_openclaw():
    """Find openclaw CLI binary."""
    import subprocess as sp
    for p in ["/opt/homebrew/bin/openclaw", os.path.expanduser("~/.npm-global/bin/openclaw")]:
        if os.path.exists(p):
            return p
    try:
        result = sp.run(["which", "openclaw"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None


def broadcast_report(results: dict, dry_run: bool = False) -> bool:
    """Send maintenance report via Zoe (main agent) to Discord."""
    import subprocess as sp

    lines = ["[Memory Maintenance Weekly Report]", ""]

    any_action = False
    for agent, result in results.items():
        status = result.get("memory_status", {})
        daily = result.get("daily_memory_archived", 0)
        learnings = result.get("learnings_promoted_cleaned", 0)
        knowledge = result.get("knowledge_daily_archived", 0)
        sections = status.get("archived_sections", 0)
        warning = status.get("warning", False)
        mem_lines = status.get("lines", 0)

        if daily + learnings + knowledge + sections > 0 or warning:
            any_action = True
            agent_lines = [f"**{agent}** (MEMORY: {mem_lines} lines{' warning' if warning else ''})"]
            if sections > 0:
                agent_lines.append(f"  - MEMORY.md: {sections} old sections archived")
            if learnings > 0:
                agent_lines.append(f"  - LEARNINGS: {learnings} promoted entries cleaned")
            if daily > 0:
                agent_lines.append(f"  - Daily notes: {daily} files archived (>14d)")
            if knowledge > 0:
                agent_lines.append(f"  - Knowledge: {knowledge} dirs archived (>30d)")
            if warning and sections == 0:
                agent_lines.append(f"  - MEMORY.md exceeds 200 lines, needs manual review")
            lines.extend(agent_lines)
            lines.append("")

    if not any_action:
        lines.append("All agents healthy. No maintenance actions needed.")
        lines.append("")

    message = "\n".join(lines)

    if dry_run:
        log(f"[BROADCAST DRY RUN]\n{message}")
        return True

    openclaw = _find_openclaw()
    if not openclaw:
        log("[BROADCAST] openclaw binary not found, skipping")
        return False

    node_path = "/opt/homebrew/bin/node"
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:" + env.get("PATH", "")

    cmd = [
        node_path, openclaw,
        "agent", "--agent", "main",
        "--channel", "discord",
        "--deliver",
        "--message", message,
    ]

    try:
        result = sp.run(cmd, capture_output=True, text=True, timeout=60, env=env)
        if result.returncode == 0:
            log("[BROADCAST] Sent to Discord via Zoe")
            return True
        else:
            log(f"[BROADCAST] Failed: {result.stderr[:200]}")
            return False
    except Exception as e:
        log(f"[BROADCAST] Error: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="OpenClaw Memory Maintenance")
    parser.add_argument("--agents", nargs="+", default=["main"],
                        help="Agents to maintain (default: main)")
    parser.add_argument("--all", action="store_true",
                        help="Maintain all agents")
    parser.add_argument("--dry-run", action="store_true",
                        help="Check sizes without archiving")
    parser.add_argument("--json", action="store_true",
                        help="Output JSON results")
    parser.add_argument("--broadcast", action="store_true",
                        help="Send report to Discord via Zoe")
    args = parser.parse_args()

    agents = list(AGENT_WORKSPACES.keys()) if args.all else args.agents

    log(f"Memory maintenance starting for: {', '.join(agents)}")
    results = run_maintenance(agents, dry_run=args.dry_run)

    if args.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
    else:
        log("=" * 50)
        log("Summary:")
        for agent, result in results.items():
            status = result["memory_status"]
            archived = status.get("archived_sections", 0)
            log(f"  {agent}: MEMORY={status.get('lines', 0)} lines"
                f" | daily_archived={result['daily_memory_archived']}"
                f" | learnings_cleaned={result['learnings_promoted_cleaned']}"
                f" | knowledge_archived={result['knowledge_daily_archived']}"
                f" | memory_sections_archived={archived}"
                + (" ⚠️" if status.get("warning") else " ✅"))

    if args.broadcast:
        broadcast_report(results, dry_run=args.dry_run)

    report_path = os.path.expanduser("~/.openclaw/shared-context/memory-maintenance-latest.json")
    report = {
        "timestamp": datetime.now().isoformat(),
        "agents": {agent: {
            "memory_lines": r.get("memory_status", {}).get("lines", 0),
            "memory_warning": r.get("memory_status", {}).get("warning", False),
            "memory_sections_archived": r.get("memory_status", {}).get("archived_sections", 0),
            "daily_memory_archived": r.get("daily_memory_archived", 0),
            "learnings_promoted_cleaned": r.get("learnings_promoted_cleaned", 0),
            "knowledge_daily_archived": r.get("knowledge_daily_archived", 0),
        } for agent, r in results.items()},
        "dry_run": args.dry_run,
    }
    Path(report_path).parent.mkdir(parents=True, exist_ok=True)
    Path(report_path).write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    log(f"Report saved to {report_path}")

    log("Done.")


if __name__ == "__main__":
    main()
