#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <ip-or-hostname>" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  log_error "This script is for macOS only."
  exit 1
fi

if ! command -v ping &>/dev/null; then
  log_error "'ping' is not installed."
  exit 1
fi

readonly TARGET="$1"
readonly MIN_PAYLOAD=1200
readonly MAX_PAYLOAD=1472
readonly TIMEOUT_MS=1000
readonly IPV4_OVERHEAD=28
readonly MIN_RECOMMENDED_MTU=1280

check_payload() {
  local size="$1"
  # macOS ping:
  # -D         set Don't Fragment bit
  # -c 1       send 1 packet
  # -W 1000    timeout in milliseconds
  # -s N       payload size
  ping -c 1 -W "${TIMEOUT_MS}" -D -s "${size}" "${TARGET}" >/dev/null 2>&1
}

log_info "Target: ${TARGET}"
log_info "Testing payload range: ${MIN_PAYLOAD}..${MAX_PAYLOAD}"
echo ""

low="${MIN_PAYLOAD}"
high="${MAX_PAYLOAD}"
best=0

while [[ "${low}" -le "${high}" ]]; do
  mid=$(( (low + high) / 2 ))
  if check_payload "${mid}"; then
    best="${mid}"
    low=$(( mid + 1 ))
  else
    high=$(( mid - 1 ))
  fi
done

if [[ "${best}" -eq 0 ]]; then
  log_error "No working payload found in tested range (${MIN_PAYLOAD}..${MAX_PAYLOAD})."
  log_error "Try lowering MIN_PAYLOAD in mtu.sh."
  exit 2
fi

path_mtu=$(( best + IPV4_OVERHEAD ))
rec_80=$(( path_mtu - 80 ))
rec_60=$(( path_mtu - 60 ))
rec_40=$(( path_mtu - 40 ))

if [[ "${rec_80}" -lt "${MIN_RECOMMENDED_MTU}" ]]; then rec_80="${MIN_RECOMMENDED_MTU}"; fi
if [[ "${rec_60}" -lt "${MIN_RECOMMENDED_MTU}" ]]; then rec_60="${MIN_RECOMMENDED_MTU}"; fi
if [[ "${rec_40}" -lt "${MIN_RECOMMENDED_MTU}" ]]; then rec_40="${MIN_RECOMMENDED_MTU}"; fi

echo "Result:"
echo "  Max payload without fragmentation: ${best}"
echo "  Estimated path MTU:               ${path_mtu}"
echo ""
echo "Recommended MTU for WireGuard/AmneziaWG:"
echo "  Conservative: ${rec_80}"
echo "  Balanced:     ${rec_60}"
echo "  Aggressive:   ${rec_40}"
echo ""
echo "Good starting point: ${rec_60}"
