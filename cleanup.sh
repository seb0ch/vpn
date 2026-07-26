#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo "This will permanently remove:"
echo "  • VPN containers (vpn-amneziawg, vpn-xray, vpn-dns) and their Docker network"
echo "  • Docker images:  amneziawg, xray, dns (all tags)"
echo "  • Generated server configs and keys"
echo "  • All client configs and QR codes"
echo "  • Host artifacts: vpn-host-firewall.service + its INPUT rule,"
echo "    amneziawg-module.service, the conntrack drop-ins,"
echo "    and /etc/modules-load.d/amneziawg.conf"
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
  for ctr in vpn-amneziawg vpn-xray vpn-dns; do
    docker rm -f "${ctr}" 2>/dev/null || true
  done
  docker network rm vpn 2>/dev/null || true
fi

# ── Remove Docker images ──────────────────────────────────────────────────────
# Images are tagged with their component release (e.g. xray:v26.6.1), so remove
# every tag of each repository, not just a bare ":latest".
log_info "Removing Docker images…"
for repo in amneziawg xray dns; do
  mapfile -t refs < <(docker images "${repo}" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
  if [[ ${#refs[@]} -gt 0 ]]; then
    docker image rm "${refs[@]}" >/dev/null
    log_info "  Removed images: ${refs[*]}"
  else
    log_info "  No '${repo}' images found — skipping."
  fi
done

# ── Remove generated configs and keys ─────────────────────────────────────────
log_info "Removing generated configs, keys, and client files…"

rm -f docker-compose.yml
rm -rf clients
rm -f amneziawg/conf/awg0.conf
rm -f amneziawg/conf/awg0.conf.lock
rm -f amneziawg/conf/server_private.key
rm -f amneziawg/conf/server_public.key
rm -f xray/conf/config.json
rm -f xray/conf/config.json.lock
rm -f xray/conf/reality_keys.txt

# Transient files that survive only if an add-client run died mid-way.
rm -f amneziawg/conf/.next_ip_* xray/conf/.conn_info_*

# ── Remove host-level artifacts installed by deploy.sh ────────────────────────
# These persist outside the repo and would otherwise affect future containers
# on 172.20.0.0/24 (the INPUT rule) or other modules at boot (modules-load.d).
log_info "Removing host-level artifacts…"

if [[ -f /etc/systemd/system/vpn-host-firewall.service ]]; then
  systemctl disable --now vpn-host-firewall.service 2>/dev/null || true
  rm -f /etc/systemd/system/vpn-host-firewall.service
  systemctl daemon-reload 2>/dev/null || true
  log_info "  Removed vpn-host-firewall.service"
fi

# Drop the INPUT rule if still present (idempotent: -C succeeds only if it exists).
while iptables -C INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP 2>/dev/null; do
  iptables -D INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP
  log_info "  Removed host INPUT rule (block NEW from 172.20.0.0/24)"
done

if [[ -f /etc/modules-load.d/amneziawg.conf ]]; then
  rm -f /etc/modules-load.d/amneziawg.conf
  log_info "  Removed /etc/modules-load.d/amneziawg.conf (module stays loaded until reboot)"
fi

# Host-wide conntrack tuning drop-ins. Removing the files restores the kernel
# defaults on the next reboot; the raised live limits persist until then.
for f in /etc/sysctl.d/99-vpn-conntrack.conf /etc/modprobe.d/vpn-conntrack.conf /etc/modules-load.d/vpn-conntrack.conf; do
  if [[ -f "${f}" ]]; then
    rm -f "${f}"
    log_info "  Removed ${f} (live conntrack limits persist until reboot)"
  fi
done

echo ""
log_info "Cleanup complete. The repository is back to a clean state."
echo ""
echo "To redeploy from scratch:"
echo "  sudo ./deploy.sh"
