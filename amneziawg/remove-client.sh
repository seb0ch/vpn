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

readonly CONF="conf/awg0.conf"
readonly CLIENT_CONF="conf/client_${CLIENT_NAME}.conf"

if [[ ! -f "${CLIENT_CONF}" ]]; then
  log_error "Client '${CLIENT_NAME}' not found (${CLIENT_CONF} missing)."
  exit 1
fi

CLIENT_PUBLIC_KEY=$(awk '/^PublicKey/{print $3}' "${CLIENT_CONF}")
if [[ -z "${CLIENT_PUBLIC_KEY}" ]]; then
  log_error "Could not read PublicKey from ${CLIENT_CONF}."
  exit 1
fi

# ── Remove the [Peer] block from the server config (locked) ──────────────────
# Each peer block is: blank line, [Peer], # <name>, key=value lines.
(
  flock -x 200 || { log_error "Could not acquire lock on ${CONF}"; exit 1; }

  AWG_CLIENT="${CLIENT_NAME}" AWG_CONF="${CONF}" python3 - <<'PYEOF'
import os, re

client = re.escape(os.environ['AWG_CLIENT'])
conf   = os.environ['AWG_CONF']

with open(conf) as f:
    text = f.read()

# Match: newline, [Peer], # <name>, then all non-empty lines.
text = re.sub(r'\n\[Peer\]\n# ' + client + r'\n(?:[^\n]+\n)*', '\n', text)
text = re.sub(r'\n{3,}', '\n\n', text).rstrip() + '\n'

with open(conf, 'w') as f:
    f.write(text)
PYEOF
) 200>"${CONF}.lock"

# ── Delete client files ────────��──────────────────────────────────────────────
rm -f "${CLIENT_CONF}" "conf/client_${CLIENT_NAME}.png"

# ── Hot-reload: sync config without restarting ────────────────────────────────
docker exec amneziawg sh -c '
  grep -v -E "^(Address|PostUp|PostDown|SaveConfig|MTU|DNS|Table|PreUp|PreDown)\s*=" /etc/awg/awg0.conf > /tmp/awg0_stripped.conf
  awg syncconf awg0 /tmp/awg0_stripped.conf
  rm -f /tmp/awg0_stripped.conf
'


log_info "Client '${CLIENT_NAME}' removed."
