#!/usr/bin/env python3
"""Switch OpenClaw model providers.

Usage:
  switch_model.py                        # Show status
  switch_model.py ciykj [-r]             # Switch default model
  switch_model.py gmn [-r]               # Switch default model  
  switch_model.py qwen [-r]              # Switch default model
  switch_model.py --group reflect <model> [-r]   # Switch reflection+followup crons
  switch_model.py --group review <model> [-r]    # Switch review/roundtable crons
  switch_model.py --cron <model> [-r]            # Switch ALL crons (use with caution)
"""

import json
import subprocess
import sys
import os

CONFIG = os.path.expanduser("~/.openclaw/openclaw.json")
CRON_FILE = os.path.expanduser("~/.openclaw/cron/jobs.json")

PROVIDERS = {
    "ciykj": {"model": "ciykj/gpt-5.4",          "label": "新中转 w.ciykj.cn (GPT-5.4)"},
    "gmn":   {"model": "gmn/gpt-5.4",            "label": "老中转 gmn.chuangzuoli.com (GPT-5.4)"},
    "qwen":  {"model": "bailian/qwen3.5-plus",    "label": "百炼 Qwen3.5-Plus (国内直连)"},
}

ALIASES = {"new": "ciykj", "old": "gmn", "bailian": "qwen", "qwen3.5": "qwen",
           "新中转": "ciykj", "老中转": "gmn", "新": "ciykj", "老": "gmn"}

GROUPS = {
    "reflect": {
        "label": "反思+跟进任务",
        "match": lambda name: "reflection" in name or "followup" in name,
    },
    "review": {
        "label": "回顾/站会任务",
        "match": lambda name: any(k in name for k in [
            "morning-brief", "weekly-review", "opening-bell",
            "closing-summary", "roundtable"
        ]),
    },
    "high": {
        "label": "高级任务 (反思+跟进+回顾)",
        "match": lambda name: any(k in name for k in [
            "reflection", "followup", "morning-brief", "weekly-review",
            "opening-bell", "closing-summary", "roundtable"
        ]),
    },
}

def load_json(path):
    with open(path) as f:
        return json.load(f)

def save_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")

def resolve_name(name):
    return ALIASES.get(name.lower().strip(), name.lower().strip())

def resolve_model(target):
    resolved = resolve_name(target)
    return PROVIDERS.get(resolved, {}).get("model", target)

def get_current(d):
    primary = d.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "?")
    for name, info in PROVIDERS.items():
        if info["model"] == primary:
            return name
    return primary

def restart_gateway():
    uid = subprocess.run(["id", "-u"], capture_output=True, text=True).stdout.strip()
    result = subprocess.run(
        ["launchctl", "kickstart", "-k", f"gui/{uid}/ai.openclaw.gateway"],
        capture_output=True, text=True
    )
    print("Gateway restarting..." if result.returncode == 0 else f"Restart failed: {result.stderr}")

def switch_default(target, auto_restart=False):
    target = resolve_name(target)
    if target not in PROVIDERS:
        print(f"Unknown: {target}. Available: {', '.join(PROVIDERS.keys())}")
        sys.exit(1)

    d = load_json(CONFIG)
    current = get_current(d)
    if current == target:
        print(f"Already: {target} ({PROVIDERS[target]['label']})")
        return
    d["agents"]["defaults"]["model"]["primary"] = PROVIDERS[target]["model"]
    save_json(CONFIG, d)
    print(f"Default: {current} -> {target} ({PROVIDERS[target]['label']})")
    if auto_restart:
        restart_gateway()

def switch_cron_group(group_name, target_model, auto_restart=False):
    if group_name not in GROUPS:
        print(f"Unknown group: {group_name}. Available: {', '.join(GROUPS.keys())}")
        sys.exit(1)

    group = GROUPS[group_name]
    data = load_json(CRON_FILE)
    jobs = data if isinstance(data, list) else data.get("jobs", [])

    changed = []
    for j in jobs:
        if not isinstance(j, dict) or not j.get("enabled", True):
            continue
        name = j.get("name", "")
        if group["match"](name):
            payload = j.get("payload", {})
            if isinstance(payload, dict):
                old = payload.get("model", "default")
                if old != target_model:
                    payload["model"] = target_model
                    changed.append(f"  {name}: {old} -> {target_model}")

    save_json(CRON_FILE, data)
    print(f"Group '{group_name}' ({group['label']}): {len(changed)} jobs switched to {target_model}")
    for c in changed:
        print(c)
    if auto_restart:
        restart_gateway()

def switch_all_cron(target_model, auto_restart=False):
    data = load_json(CRON_FILE)
    jobs = data if isinstance(data, list) else data.get("jobs", [])
    changed = 0
    for j in jobs:
        if not isinstance(j, dict) or not j.get("enabled", True):
            continue
        payload = j.get("payload", {})
        if isinstance(payload, dict) and "model" in payload and payload["model"] != target_model:
            payload["model"] = target_model
            changed += 1
    save_json(CRON_FILE, data)
    total = sum(1 for j in jobs if isinstance(j, dict) and j.get("enabled", True))
    print(f"All cron: {changed}/{total} jobs switched to {target_model}")
    if auto_restart:
        restart_gateway()

def show_status():
    d = load_json(CONFIG)
    current = get_current(d)
    label = PROVIDERS.get(current, {}).get("label", "unknown")
    print(f"Default: {current} ({label})")
    print()
    for name, info in PROVIDERS.items():
        marker = " <--" if name == current else ""
        print(f"  {name}: {info['label']}{marker}")

    data = load_json(CRON_FILE)
    jobs = data if isinstance(data, list) else data.get("jobs", [])

    print(f"\nCron groups:")
    for gname, group in GROUPS.items():
        matched = [(j.get("name","?"), j.get("payload",{}).get("model","?") if isinstance(j.get("payload"),dict) else "?")
                    for j in jobs if isinstance(j, dict) and j.get("enabled", True) and group["match"](j.get("name",""))]
        if matched:
            models = set(m for _, m in matched)
            print(f"  {gname} ({group['label']}): {len(matched)} jobs -> {', '.join(models)}")

    by_model = {}
    for j in jobs:
        if isinstance(j, dict) and j.get("enabled", True):
            m = j.get("payload", {}).get("model", "default") if isinstance(j.get("payload"), dict) else "?"
            by_model[m] = by_model.get(m, 0) + 1
    print(f"\nAll cron ({sum(by_model.values())}):")
    for m, c in sorted(by_model.items(), key=lambda x: -x[1]):
        print(f"  {m}: {c}")

    print(f"\nUsage:")
    print(f"  switch_model.py <ciykj|gmn|qwen> [-r]")
    print(f"  switch_model.py --group <reflect|review|high> <ciykj|gmn|qwen> [-r]")
    print(f"  switch_model.py --cron <model> [-r]")

def main():
    raw_args = sys.argv[1:]
    auto_restart = "-r" in raw_args or "--restart" in raw_args
    args = [a for a in raw_args if a not in ("-r", "--restart", "--group", "--cron")]

    if "--group" in raw_args:
        idx = raw_args.index("--group")
        remaining = [a for a in raw_args[idx+1:] if a not in ("-r", "--restart")]
        if len(remaining) >= 2:
            group_name = remaining[0]
            target = resolve_model(remaining[1])
            switch_cron_group(group_name, target, auto_restart)
        else:
            print("Usage: switch_model.py --group <reflect|review|high> <ciykj|gmn|qwen> [-r]")
    elif "--cron" in raw_args:
        idx = raw_args.index("--cron")
        remaining = [a for a in raw_args[idx+1:] if a not in ("-r", "--restart")]
        if remaining:
            target = resolve_model(remaining[0])
            switch_all_cron(target, auto_restart)
        else:
            print("Usage: switch_model.py --cron <model> [-r]")
    elif args:
        switch_default(args[0], auto_restart)
    else:
        show_status()

if __name__ == "__main__":
    main()
