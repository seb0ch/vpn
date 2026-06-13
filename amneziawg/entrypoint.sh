#!/usr/bin/env bash
set -euo pipefail

IFACE="awg0"
CONF="/etc/awg/awg0.conf"

# ── The amneziawg kernel module must already be loaded by the host ───────────
# (deploy.sh / rebuild-amneziawg.sh load it and persist it via
# /etc/modules-load.d/amneziawg.conf). The container deliberately has no
# CAP_SYS_MODULE, so it cannot — and must not — load it itself.
#
# Read /proc/modules directly rather than `lsmod | grep -q`: under
# `set -o pipefail`, grep -q closes the pipe on its first match and lsmod
# dies with SIGPIPE (141), making the whole pipeline "fail" even though the
# module IS present — a false negative that crash-loops the container.
if ! grep -q '^amneziawg ' /proc/modules; then
  echo "Error: amneziawg kernel module is not loaded on the host." >&2
  echo "First install:        sudo ./deploy.sh" >&2
  echo "After kernel upgrade: docker compose stop amneziawg &&" >&2
  echo "                      sudo ./rebuild-amneziawg.sh &&" >&2
  echo "                      docker compose start amneziawg" >&2
  echo "Boot persistence:     check /etc/modules-load.d/amneziawg.conf exists." >&2
  exit 1
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
