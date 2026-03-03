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

log_info "--- AmneziaWG ---"
"${SCRIPT_DIR}/amneziawg/remove-client.sh" "${CLIENT_NAME}"
echo ""

log_info "--- Xray REALITY ---"
"${SCRIPT_DIR}/xray/remove-client.sh" "${CLIENT_NAME}"
