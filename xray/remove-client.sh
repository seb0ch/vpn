#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <client_name>" >&2
  exit 1
fi

readonly CLIENT_NAME="$1"
validate_client_name "${CLIENT_NAME}"

readonly CONFIG="conf/config.json"

# ── Remove client from config.json (locked to prevent concurrent races) ──────
XR_CLIENT="${CLIENT_NAME}" XR_CONFIG="${CONFIG}" \
python3 - <<'PYEOF'
import json, os, sys

config_path = os.environ['XR_CONFIG']
name        = os.environ['XR_CLIENT']

with open(config_path) as f:
    config = json.load(f)

clients = config['inbounds'][0]['settings']['clients']
filtered = [c for c in clients if c.get('email') != name]

if len(filtered) == len(clients):
    print(f"Error: client '{name}' not found in config.json", file=sys.stderr)
    sys.exit(1)

config['inbounds'][0]['settings']['clients'] = filtered

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print(f"Client '{name}' removed from config.json.")
PYEOF

# ── Restart service to apply the updated configs ─────────────────────────
docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" restart xray >/dev/null

log_info "Client '${CLIENT_NAME}' removed."
