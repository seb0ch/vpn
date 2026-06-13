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
readonly CLIENT_CONF="../clients/${CLIENT_NAME}_amneziawg.conf"

# ── Remove the [Peer] block from the server config (locked) ──────────────────
# remove-peer.py matches the peer by its `# <name>` comment; it exits 3 when
# the peer does not exist.
# NOTE: `set -e` is suppressed inside `( ... ) || RC=$?`, so the python call
# needs an explicit `|| exit` to propagate its status out of the subshell.
RC=0
(
  flock -x 200 || { log_error "Could not acquire lock on ${CONF}"; exit 1; }
  AWG_CLIENT="${CLIENT_NAME}" AWG_CONF="${CONF}" python3 remove-peer.py || exit
) 200>"${CONF}.lock" || RC=$?

if [[ "${RC}" -eq 3 ]]; then
  # Idempotent recovery: a previous run may have updated awg0.conf but died
  # before the syncconf. Converge the runtime state and clean up anyway.
  log_warn "Client '${CLIENT_NAME}' has no [Peer] entry in ${CONF} (already removed?) — syncing interface anyway."
elif [[ "${RC}" -ne 0 ]]; then
  log_error "Failed to update ${CONF} (exit ${RC})."
  exit "${RC}"
fi

# ── Delete client files ───────────────────────────────────────────────────────
rm -f "${CLIENT_CONF}"

# ── Hot-reload: sync config without restarting ────────────────────────────────
docker exec amneziawg sh -c '
  grep -v -E "^(Address|PostUp|PostDown|SaveConfig|MTU|DNS|Table|PreUp|PreDown)\s*=" /etc/awg/awg0.conf > /tmp/awg0_stripped.conf
  awg syncconf awg0 /tmp/awg0_stripped.conf
  rm -f /tmp/awg0_stripped.conf
'

log_info "Client '${CLIENT_NAME}' removed."
