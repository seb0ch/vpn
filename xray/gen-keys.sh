#!/usr/bin/env bash
set -euo pipefail
umask 077   # every file created below holds key material

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly KEYS_FILE="conf/reality_keys.txt"
readonly CONFIG="conf/config.json"

# ── Bootstrap config from template if missing ─────────────────────────────────
if [[ ! -f "${CONFIG}" ]]; then
  [[ -f conf/config.json.tmpl ]] || { log_error "conf/config.json.tmpl not found"; exit 1; }
  cp conf/config.json.tmpl "${CONFIG}"
  chmod 600 "${CONFIG}"
  log_info "Created ${CONFIG} from template"
fi

# ── Generate X25519 keypair ───────────────────────────────────────────────────
log_info "Generating REALITY keys…"
KEYS=$(docker run --rm --entrypoint xray xray x25519 2>&1)

# Parse output robustly — handle both "Private key: x" and "PrivateKey: x" formats.
PRIVATE_KEY=$(printf '%s\n' "${KEYS}" | awk '/[Pp]rivate.*[Kk]ey/{print $NF}')
PUBLIC_KEY=$(printf  '%s\n' "${KEYS}" | awk '/[Pp]ublic.*[Kk]ey|[Pp]assword/{print $NF}')
SHORT_ID=$(openssl rand -hex 8)

[[ -n "${PRIVATE_KEY}" ]] || { log_error "Failed to parse private key from 'xray x25519' output."; exit 1; }
[[ -n "${PUBLIC_KEY}"  ]] || { log_error "Failed to parse public key from 'xray x25519' output.";  exit 1; }

# ── Persist keys + patch config.json (locked to prevent races) ────────────────
# Both reality_keys.txt and config.json are written under the same lock so that
# add-client.sh always reads a consistent pair of public key + short ID.
(
  flock -x 200 || { log_error "Could not acquire lock on ${CONFIG}"; exit 1; }

  cat > "${KEYS_FILE}" <<KEYS_EOF
Private key: ${PRIVATE_KEY}
Public key:  ${PUBLIC_KEY}
Short ID:    ${SHORT_ID}
KEYS_EOF
  chmod 600 "${KEYS_FILE}"
  log_info "Keys saved to ${KEYS_FILE}"

  PRIVATE_KEY="${PRIVATE_KEY}" SHORT_ID="${SHORT_ID}" XR_CONFIG="${CONFIG}" \
  python3 - <<'PYEOF'
import json, os

config_path = os.environ['XR_CONFIG']
with open(config_path) as f:
    config = json.load(f)

rs = config['inbounds'][0]['streamSettings']['realitySettings']
rs['privateKey'] = os.environ['PRIVATE_KEY']
rs['shortIds']   = [os.environ['SHORT_ID']]

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print("[INFO]  config.json updated.")
PYEOF
) 200>"${CONFIG}.lock"

echo ""
echo "Public key (share with clients): ${PUBLIC_KEY}"
