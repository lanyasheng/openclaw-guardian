#!/usr/bin/env python3
"""Check cron job health status + Chrome CDP health - reports failed/missed critical tasks."""

import json
from datetime import datetime, timezone, timedelta

BJ = timezone(timedelta(hours=8))
NOW = datetime.now(BJ)
TODAY_START = NOW.replace(hour=0, minute=0, second=0, microsecond=0)
TODAY_START_MS = int(TODAY_START.timestamp() * 1000)

CRITICAL_JOBS = [
    "ainews-morning-digest", "ainews-paper-digest", "ainews-evening-report",
    "daily-reflection-ainews",
    "trading-morning-brief", "trading-opening-bell", "trading-closing-summary",
    "daily-reflection-trading",
    "macro-daily-check", "finance-news-evening",
    "daily-reflection-macro", "daily-reflection-main",
]

with open("/Users/study/.openclaw/cron/jobs.json") as f:
    data = json.load(f)

failed = []
missed = []
ok_count = 0
checked = 0

for j in data.get("jobs", []):
    if not j.get("enabled"):
        continue
    name = j.get("name", "")
    if name not in CRITICAL_JOBS:
        continue

    checked += 1
    jid = j.get("id", "?")
    state = j.get("state", {})
    last_run = state.get("lastRunAtMs", 0)
    status = state.get("lastRunStatus", "?")
    delivery = state.get("lastDeliveryStatus", "?")
    next_run = state.get("nextRunAtMs", 0)

    last_run_str = "never"
    if last_run:
        t = datetime.fromtimestamp(last_run / 1000, tz=BJ)
        last_run_str = t.strftime("%H:%M")

    if status == "error" and last_run > TODAY_START_MS:
        failed.append(f"{name} (ID: {jid}): status=error, lastRun={last_run_str}")
    elif delivery == "not-delivered" and last_run > TODAY_START_MS:
        failed.append(f"{name} (ID: {jid}): not-delivered, lastRun={last_run_str}")
    elif next_run and next_run < int(NOW.timestamp() * 1000) and last_run < TODAY_START_MS:
        missed.append(f"{name} (ID: {jid}): missed, lastRun={last_run_str}")
    else:
        ok_count += 1

print(f"Checked at: {NOW.strftime('%Y-%m-%d %H:%M')}")
print(f"Status: {ok_count}/{checked} OK")
print()

if failed:
    print("FAILED TODAY:")
    for f in failed:
        print(f"  RETRY: {f}")
else:
    print("NO FAILURES")

if missed:
    print("\nMISSED (should have run but didn't):")
    for m in missed:
        print(f"  RETRY: {m}")

if not failed and not missed:
    print("\nALL CRITICAL TASKS HEALTHY")

# Chrome CDP health check
print("\n--- Chrome CDP Health ---")
import urllib.request, socket, subprocess, os

socket.setdefaulttimeout(5)
cdp_ok = False
try:
    resp = urllib.request.urlopen("http://127.0.0.1:18800/json/version")
    info = json.loads(resp.read())
    browser = info.get("Browser", "unknown")
    print(f"CDP: OK ({browser})")
    cdp_ok = True
except Exception as e:
    print(f"CDP: FAILED - {e}")
    print("AUTO-REPAIR: Attempting Chrome restart...")
    try:
        os.system("pkill -f 'remote-debugging-port=18800' 2>/dev/null")
        import time
        time.sleep(2)
        for lockf in ["SingletonLock", "SingletonSocket", "SingletonCookie"]:
            path = f"/Users/study/.openclaw/browser/openclaw/user-data/{lockf}"
            if os.path.exists(path):
                os.remove(path)
        os.system(
            'nohup /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome '
            '--remote-debugging-port=18800 '
            '"--remote-allow-origins=*" '
            '--user-data-dir=/Users/study/.openclaw/browser/openclaw/user-data '
            '--no-first-run --no-default-browser-check --disable-sync '
            '--disable-background-networking --disable-component-update '
            '"--disable-features=Translate,MediaRouter" '
            '--disable-session-crashed-bubble --hide-crash-restore-bubble '
            '--password-store=basic --disable-blink-features=AutomationControlled '
            'about:blank > /dev/null 2>&1 &'
        )
        time.sleep(4)
        resp = urllib.request.urlopen("http://127.0.0.1:18800/json/version")
        info = json.loads(resp.read())
        print(f"AUTO-REPAIR: SUCCESS - Chrome restarted ({info.get('Browser','?')})")
        cdp_ok = True
    except Exception as e2:
        print(f"AUTO-REPAIR: FAILED - {e2}")
        print("ACTION NEEDED: Manual Chrome restart required")

if not cdp_ok:
    print("RETRY: Chrome CDP is down, browser-based tasks will fail")
