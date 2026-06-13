#!/usr/bin/env python3
"""Remove a client (matched by email) from an Xray config.json.

Env: XR_CLIENT (client name/email), XR_CONFIG (path to config.json).
Exit codes: 0 removed, 3 client not found.
"""
import json
import os
import sys
import tempfile

config_path = os.environ['XR_CONFIG']
name = os.environ['XR_CLIENT']

with open(config_path) as f:
    config = json.load(f)

clients = config['inbounds'][0]['settings']['clients']
filtered = [c for c in clients if c.get('email') != name]

if len(filtered) == len(clients):
    sys.exit(3)

config['inbounds'][0]['settings']['clients'] = filtered

# Strip this client from every per-user routing rule too, otherwise a dangling
# rule survives and a later client re-added under the same name silently
# inherits the old upstream route. Mirrors set-route.sh: a rule dedicated to
# this client is dropped; a group rule keeps its other members.
rules = (config.get('routing') or {}).get('rules')
if rules:
    new_rules = []
    for r in rules:
        users = r.get('user') or []
        if name in users:
            remaining = [u for u in users if u != name]
            if remaining:
                new_rules.append({**r, 'user': remaining})
            # else: rule was dedicated to this client; drop it.
        else:
            new_rules.append(r)
    rules[:] = new_rules

# Atomic write: temp file + fsync + rename (same pattern as add-upstream.sh).
cfg_dir = os.path.dirname(os.path.abspath(config_path)) or '.'
fd, tmp = tempfile.mkstemp(dir=cfg_dir, prefix='.config.', suffix='.json.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(config, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chmod(tmp, os.stat(config_path).st_mode & 0o777)
    except FileNotFoundError:
        pass
    os.replace(tmp, config_path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
