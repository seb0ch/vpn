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
readonly COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose.yml"

# ── Remove client from config.json (locked, atomic) ──────────────────────────
# remove-client.py exits 3 when the client is not in config.json.
# NOTE: `set -e` is suppressed inside `( ... ) || RC=$?`, so the python call
# needs an explicit `|| exit` to propagate its status out of the subshell.
RC=0
(
  flock -x 200 || { log_error "Could not acquire lock on ${CONFIG}"; exit 1; }

  XR_CLIENT="${CLIENT_NAME}" XR_CONFIG="${CONFIG}" python3 remove-client.py || exit

  # Restart inside the lock so a concurrent mutator cannot interleave between
  # our replace and the restart (same rationale as add-upstream.sh).
  docker compose -f "${COMPOSE_FILE}" restart xray >/dev/null \
    || { log_error "Failed to restart xray container"; exit 1; }
) 200>"${CONFIG}.lock" || RC=$?

if [[ "${RC}" -eq 3 ]]; then
  # Idempotent recovery: a previous run may have updated config.json but died
  # before the restart. Converge the runtime state and clean up anyway.
  log_warn "Client '${CLIENT_NAME}' not in ${CONFIG} (already removed?) — restarting xray to converge."
  docker compose -f "${COMPOSE_FILE}" restart xray >/dev/null \
    || { log_error "Failed to restart xray container"; exit 1; }
elif [[ "${RC}" -ne 0 ]]; then
  log_error "Failed to update ${CONFIG} (exit ${RC})."
  exit "${RC}"
fi

# ── Delete client credential files ────────────────────────────────────────────
rm -f "../clients/${CLIENT_NAME}_xray.vless" "../clients/${CLIENT_NAME}_xray.png"

log_info "Client '${CLIENT_NAME}' removed."
