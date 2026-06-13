#!/usr/bin/env bash
set -euo pipefail
umask 077   # the .vless link and QR PNG are bearer credentials

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

# ── Generate a fresh UUID for this client ─────────────────────────────────────
UUID=$(docker exec xray xray uuid)
[[ -n "${UUID}" ]] || { log_error "Failed to generate UUID (is the xray container running?)"; exit 1; }

# ── Read connection details, check for duplicates, append client (locked) ────
SERVER_IP=$(get_public_ip)
readonly CONN_INFO="conf/.conn_info_${CLIENT_NAME}"

(
  flock -x 200 || { log_error "Could not acquire lock on ${CONFIG}"; exit 1; }

  UUID="${UUID}" XR_CLIENT="${CLIENT_NAME}" XR_CONFIG="${CONFIG}" \
    XR_CONN_INFO="${CONN_INFO}" \
  python3 - <<'PYEOF'
import json, os, sys

config_path = os.environ['XR_CONFIG']
name        = os.environ['XR_CLIENT']

with open(config_path) as f:
    config = json.load(f)

# Read server connection details.
rs   = config['inbounds'][0]['streamSettings']['realitySettings']
port = config['inbounds'][0]['port']
sni  = rs['serverNames'][0]
sid  = rs['shortIds'][0]

keys_path = os.path.join(os.path.dirname(config_path), 'reality_keys.txt')
pub = ''
with open(keys_path) as kf:
    for line in kf:
        if 'Public key' in line:
            pub = line.split()[-1]
            break

# Check for duplicate client.
clients = config['inbounds'][0]['settings']['clients']
if any(c.get('email') == name for c in clients):
    print(f"Error: client '{name}' already exists in config.json", file=sys.stderr)
    sys.exit(1)

# Append new client.
clients.append({
    "id":    os.environ['UUID'],
    "flow":  "xtls-rprx-vision",
    "email": name,
})

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

# Export connection details for the parent shell via a temp file.
with open(os.environ['XR_CONN_INFO'], 'w') as ci:
    ci.write(f"{port} {pub} {sid} {sni}\n")
PYEOF
) 200>"${CONFIG}.lock"

read -r SERVER_PORT PUBLIC_KEY SHORT_ID SNI < "${CONN_INFO}"
rm -f "${CONN_INFO}"

# ── Restart service to pick up the new client ────────────────────────────
docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" restart xray >/dev/null

# ── Build and display VLESS connection link ───────────────────────────────────
readonly VLESS_LINK="vless://${UUID}@${SERVER_IP}:${SERVER_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${CLIENT_NAME}"
readonly VLESS_FILE="../clients/${CLIENT_NAME}_xray.vless"
readonly QR_FILE="../clients/${CLIENT_NAME}_xray.png"

echo "${VLESS_LINK}" > "${VLESS_FILE}"
echo "${VLESS_LINK}" | docker exec -i xray sh -c 'qrencode -o -' > "${QR_FILE}"
chmod 600 "${VLESS_FILE}" "${QR_FILE}"

echo ""
echo "=== Client: ${CLIENT_NAME} ==="
echo "UUID: ${UUID}"
echo ""
echo "VLESS link:"
echo "${VLESS_LINK}"
echo ""
echo "VLESS link saved to: ${VLESS_FILE}"
echo "QR code saved to: ${QR_FILE}"
echo ""
echo "QR code:"
echo "${VLESS_LINK}" \
  | docker exec -i xray sh -c 'qrencode -t ansiutf8' 2>/dev/null \
  || echo "(qrencode not available in the xray image)"
