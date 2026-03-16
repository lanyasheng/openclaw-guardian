#!/bin/bash
# Heartbeat session cleanup script
# Archives heartbeat sessions that exceed a size threshold
# Designed to run as a cron job (e.g., daily)

OPENCLAW_DIR="$HOME/.openclaw"
THRESHOLD_KB=50  # Archive sessions larger than 50KB

for agent_dir in "$OPENCLAW_DIR"/agents/*/sessions; do
  agent=$(basename "$(dirname "$agent_dir")")
  archived_dir="$agent_dir/archived"
  
  sessions_json="$agent_dir/sessions.json"
  [ -f "$sessions_json" ] || continue
  
  # Find the heartbeat session (key pattern: agent:$agent:main)
  heartbeat_session=$(python3 -c "
import json, sys
with open('$sessions_json') as f:
    data = json.load(f)
for k, v in data.items():
    if k == 'agent:${agent}:main':
        sid = v.get('sessionId', '')
        sf = v.get('sessionFile', '')
        print(f'{sid}|{sf}')
        break
" 2>/dev/null)
  
  [ -z "$heartbeat_session" ] && continue
  
  session_id=$(echo "$heartbeat_session" | cut -d'|' -f1)
  session_file=$(echo "$heartbeat_session" | cut -d'|' -f2)
  
  [ -f "$session_file" ] || continue
  
  size_kb=$(du -k "$session_file" | cut -f1)
  
  if [ "$size_kb" -gt "$THRESHOLD_KB" ]; then
    mkdir -p "$archived_dir"
    timestamp=$(date -u +"%Y-%m-%dT%H-%M-%S")
    archived_name="${session_id}.jsonl.reset.${timestamp}"
    
    mv "$session_file" "$archived_dir/$archived_name"
    echo "[$(date)] Agent '$agent': archived heartbeat session $session_id (${size_kb}KB) -> $archived_dir/$archived_name"
    
    # Update sessions.json: generate a new session ID so gateway creates fresh file
    python3 -c "
import json, uuid
with open('$sessions_json') as f:
    data = json.load(f)
key = 'agent:${agent}:main'
if key in data:
    new_id = str(uuid.uuid4())
    old_file = data[key].get('sessionFile', '')
    new_file = old_file.replace('$session_id', new_id) if old_file else ''
    data[key]['sessionId'] = new_id
    data[key]['sessionFile'] = new_file
    data[key]['compactionCount'] = 0
    with open('$sessions_json', 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f'  Updated sessions.json: new sessionId={new_id}')
" 2>/dev/null
  else
    echo "[$(date)] Agent '$agent': heartbeat session OK (${size_kb}KB < ${THRESHOLD_KB}KB threshold)"
  fi
done
