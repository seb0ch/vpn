#!/usr/bin/env bash
set -euo pipefail

IFACE="awg0"
CONF="/etc/awg/awg0.conf"

# ── Ensure the amneziawg kernel module is loaded ─────────────────────────────
if ! lsmod | grep -q '^amneziawg'; then
  echo "Loading amneziawg kernel module…"
  modprobe amneziawg || {
    echo "Error: failed to load amneziawg kernel module." >&2
    echo "Make sure the module is installed on the host (see deploy.sh)." >&2
    exit 1
  }
fi

# ── Cleanup on exit ──────────────────────────────────────────────────────────
cleanup() {
  echo "Shutting down ${IFACE}…"
  awg-quick down "${CONF}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Clean up stale state from a previous run ─────────────────────────────────
ip link delete "${IFACE}" 2>/dev/null || true

# ── Bring up the interface via awg-quick (kernel module) ─────────────────────
awg-quick up "${CONF}"

echo "=== interface ==="
ip addr show "${IFACE}"
echo "=== awg status ==="
awg show

# Keep container alive
sleep infinity &
wait $!
