#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <client_name>" >&2
  exit 1
fi

readonly CLIENT_NAME="$1"
validate_client_name "${CLIENT_NAME}"

# Revoke on the components this host deploys (see add-client.sh). A component
# that was switched off after the client was created keeps its stale entries in
# its own config; cleanup.sh or a re-enable + remove clears those.
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
AWG_DEPLOYED=0
XRAY_DEPLOYED=0
component_enabled amneziawg "${COMPOSE_FILE}" && AWG_DEPLOYED=1
component_enabled xray      "${COMPOSE_FILE}" && XRAY_DEPLOYED=1

if [[ "${AWG_DEPLOYED}" -eq 0 && "${XRAY_DEPLOYED}" -eq 0 ]]; then
  log_error "No AmneziaWG or Xray service found in ${COMPOSE_FILE} — run deploy.sh first."
  exit 1
fi

# Run both halves even if one fails: a partially-revoked client must never
# keep working credentials on the other protocol.
FAILED=0

if [[ "${AWG_DEPLOYED}" -eq 1 ]]; then
  log_info "--- AmneziaWG ---"
  "${SCRIPT_DIR}/amneziawg/remove-client.sh" "${CLIENT_NAME}" || FAILED=1
  echo ""
fi

if [[ "${XRAY_DEPLOYED}" -eq 1 ]]; then
  log_info "--- Xray REALITY ---"
  "${SCRIPT_DIR}/xray/remove-client.sh" "${CLIENT_NAME}" || FAILED=1
fi

exit "${FAILED}"
