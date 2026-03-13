"""Switch reflection task models and global defaults back to gmn/gpt-5.4."""
import json
import os

config_path = '/Users/study/.openclaw/openclaw.json'
with open(config_path, 'r') as f:
    config = json.load(f)

old_default = config['agents']['defaults']['model']['primary']
config['agents']['defaults']['model']['primary'] = 'gmn/gpt-5.4'
print(f'Global default: {old_default} -> gmn/gpt-5.4')

for agent in config.get('agents', {}).get('list', []):
    if agent.get('id') == 'content':
        model = agent.get('model', {})
        if isinstance(model, dict):
            old = model.get('primary', '')
            model['primary'] = 'gmn/gpt-5.4'
            print(f'content per-agent: {old} -> gmn/gpt-5.4')
        break

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

jobs_path = '/Users/study/.openclaw/cron/jobs.json'
with open(jobs_path, 'r') as f:
    data = json.load(f)
changed_jobs = 0
for j in data.get('jobs', []):
    if not isinstance(j, dict):
        continue
    name = j.get('name', '')
    if not name.startswith('daily-reflection-'):
        continue
    payload = j.get('payload', {})
    if 'model' in payload and payload['model'] != 'gmn/gpt-5.4':
        old_model = payload['model']
        payload['model'] = 'gmn/gpt-5.4'
        changed_jobs += 1
        print(f'  Reflection job {name}: {old_model} -> gmn/gpt-5.4')
with open(jobs_path, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print(f'Reflection jobs restored: {changed_jobs}')

agents_dir = '/Users/study/.openclaw/agents'
total = 0
for agent_name in os.listdir(agents_dir):
    sp = os.path.join(agents_dir, agent_name, 'sessions', 'sessions.json')
    if not os.path.exists(sp):
        continue
    with open(sp) as f:
        sdata = json.load(f)
    changed = 0
    for sid, sess in sdata.items():
        if isinstance(sess, dict) and sess.get('model') in ('kimi-k2.5', 'qwen3.5-plus'):
            sess['model'] = 'gpt-5.4'
            changed += 1
    if changed:
        with open(sp, 'w') as f:
            json.dump(sdata, f, indent=2, ensure_ascii=False)
        total += changed
print(f'Sessions restored: {total}')
print('Done. Remove cron entry manually.')
