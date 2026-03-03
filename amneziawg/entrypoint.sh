#!/usr/bin/env bash
set -euo pipefail

IFACE="awg0"
DNS_SERVER="172.20.0.2"
SUBNET="10.8.0.0/24"
GATEWAY="10.8.0.1/24"

# ── Cleanup on exit ───────────────────────────────────────────────────────────
# Remove every iptables rule that was added, in reverse order.
cleanup() {
  echo "Shutting down ${IFACE}…"
  iptables -t nat -D PREROUTING -i "${IFACE}" -s "${SUBNET}" -p tcp --dport 53 -j DNAT --to-destination "${DNS_SERVER}:53" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "${IFACE}" -s "${SUBNET}" -p udp --dport 53 -j DNAT --to-destination "${DNS_SERVER}:53" 2>/dev/null || true
  iptables -D FORWARD -o "${IFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "${IFACE}" -j ACCEPT 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s "${SUBNET}" -j MASQUERADE 2>/dev/null || true
  ip link set "${IFACE}" down 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Clean up stale state from a previous run (survives docker compose restart) ─
readonly UAPI_SOCK="/var/run/amneziawg/${IFACE}.sock"
rm -f "${UAPI_SOCK}"
ip link delete "${IFACE}" 2>/dev/null || true

# ── Start userspace daemon (creates TUN device + UAPI socket) ─────────────────
# amneziawg-go creates its UAPI socket at /var/run/amneziawg/<iface>.sock
# (not /var/run/wireguard/ — that is wireguard-go's path).
amneziawg-go -f "${IFACE}" >/tmp/awg.log 2>&1 &
AWG_PID=$!

# Wait up to 5 s for the UAPI socket; abort early if the daemon exits.
for i in $(seq 1 50); do
  [[ -S "${UAPI_SOCK}" ]] && break
  if ! kill -0 "${AWG_PID}" 2>/dev/null; then
    echo "Error: amneziawg-go exited before creating the UAPI socket." >&2
    echo "--- amneziawg-go output ---" >&2
    cat /tmp/awg.log >&2
    exit 1
  fi
  sleep 0.1
done

if [[ ! -S "${UAPI_SOCK}" ]]; then
  echo "Error: UAPI socket not found after 5 s — amneziawg-go may have failed." >&2
  echo "--- amneziawg-go output ---" >&2
  cat /tmp/awg.log >&2
  exit 1
fi

# ── Apply configuration ───────────────────────────────────────────────────────
awg setconf "${IFACE}" /etc/awg/awg0.conf
ip addr add "${GATEWAY}" dev "${IFACE}"
ip link set "${IFACE}" up

# ── NAT: masquerade VPN client traffic on the way out ────────────────────────
iptables -t nat -A POSTROUTING -s "${SUBNET}" -j MASQUERADE

# Allow new outbound flows from VPN clients; allow only established/related
# flows back in — this prevents arbitrary traffic being forwarded to clients.
iptables -A FORWARD -i "${IFACE}" -j ACCEPT
iptables -A FORWARD -o "${IFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# ── DNS redirect: force all client DNS to the internal forwarder ──────────────
iptables -t nat -A PREROUTING -i "${IFACE}" -s "${SUBNET}" -p udp --dport 53 -j DNAT --to-destination "${DNS_SERVER}:53"
iptables -t nat -A PREROUTING -i "${IFACE}" -s "${SUBNET}" -p tcp --dport 53 -j DNAT --to-destination "${DNS_SERVER}:53"

echo "=== interface ==="
ip addr show "${IFACE}"
echo "=== awg status ==="
awg show

# Keep container alive; exit when the daemon exits.
wait "${AWG_PID}"
