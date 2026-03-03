#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo "This will permanently remove:"
echo "  • VPN containers (amneziawg, xray, dns) and their Docker network"
echo "  • Docker images:  amneziawg, xray, dns"
echo "  • Generated server configs and keys"
echo "  • All client configs and QR codes"
echo ""
echo "Existing VPN clients will stop working immediately."
echo ""
printf "Type 'yes' to continue: "
read -r CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  log_info "Aborted."
  exit 0
fi
echo ""

# ── Stop containers + remove Docker network ───────────────────────────────────
if [[ -f docker-compose.yml ]]; then
  log_info "Stopping services…"
  docker compose down --remove-orphans 2>/dev/null || true
else
  # Compose file is already gone — remove containers and network by name.
  log_info "docker-compose.yml not found; stopping containers by name…"
  for ctr in amneziawg xray dns; do
    docker rm -f "${ctr}" 2>/dev/null || true
  done
  docker network rm vpn 2>/dev/null || true
fi

# ── Remove Docker images ──────────────────────────────────────────────────────
log_info "Removing Docker images…"
for img in amneziawg xray dns; do
  if docker image inspect "${img}" &>/dev/null; then
    docker image rm "${img}"
    log_info "  Removed image: ${img}"
  else
    log_info "  Image '${img}' not found — skipping."
  fi
done

# ── Remove generated configs and keys ─────────────────────────────────────────
log_info "Removing generated configs, keys, and client files…"

rm -f docker-compose.yml
rm -rf clients
rm -f amneziawg/conf/server_private.key
rm -f amneziawg/conf/server_public.key
rm -f xray/conf/config.json
rm -f xray/conf/reality_keys.txt

# Client files — use find to safely handle the case where none exist.
find amneziawg/conf -maxdepth 1 \( -name 'client_*.conf' -o -name 'client_*.png' \) -delete

echo ""
log_info "Cleanup complete. The repository is back to a clean state."
echo ""
echo "To redeploy from scratch:"
echo "  sudo ./deploy.sh"
