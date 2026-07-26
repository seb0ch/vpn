#!/usr/bin/env bash
set -euo pipefail

# Boot-time guard invoked by amneziawg-module.service (installed by deploy.sh).
#
# A kernel upgrade (typically via unattended-upgrades) followed by a reboot
# leaves the host running a kernel the out-of-tree AmneziaWG module was never
# built for. There is no DKMS, so the module is simply absent: modules-load.d
# fails to load it and the capability-less vpn-amneziawg container crash-loops.
#
# This script makes the module match the running kernel on every boot: if it is
# already loadable it is a no-op; if it is missing it stops the flapping
# container, rebuilds the module for the running kernel, and starts it back up.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# Already loaded → nothing to do (the common, healthy-boot case).
if grep -q '^amneziawg ' /proc/modules; then
  exit 0
fi

# On disk for this kernel but not yet loaded → just load it. Reads /proc/modules
# rather than `lsmod | grep` to avoid a pipefail SIGPIPE false negative.
if modprobe amneziawg 2>/dev/null && grep -q '^amneziawg ' /proc/modules; then
  log_info "amneziawg module loaded from existing install."
  exit 0
fi

# Module is missing for the running kernel — rebuild it. Stop the container
# first: it halts the crash loop and satisfies rebuild-amneziawg.sh's guard,
# which refuses to run while vpn-amneziawg is up.
log_warn "amneziawg module missing for kernel $(uname -r) — rebuilding."

running="$(docker ps -a --format '{{.Names}}')"
if grep -qx vpn-amneziawg <<<"${running}"; then
  if [[ -f "${COMPOSE_FILE}" ]]; then
    docker compose -f "${COMPOSE_FILE}" stop amneziawg >/dev/null 2>&1 || true
  else
    docker stop vpn-amneziawg >/dev/null 2>&1 || true
  fi
fi

# Rebuild, retrying a few times: even with network-online.target ordering the
# APT mirrors / GitHub may briefly be unreachable in the first moments of boot.
rebuilt=0
for attempt in 1 2 3; do
  if "${SCRIPT_DIR}/rebuild-amneziawg.sh"; then
    rebuilt=1
    break
  fi
  if [[ "${attempt}" -lt 3 ]]; then
    log_warn "rebuild-amneziawg.sh failed (attempt ${attempt}/3); retrying in 15s…"
    sleep 15
  fi
done

# Always bring the container back up: on success it runs normally; on failure it
# resumes its crash-loop (visible, and self-heals on a later boot) instead of
# being left stopped and forgotten for the rest of this boot.
if [[ -f "${COMPOSE_FILE}" ]]; then
  docker compose -f "${COMPOSE_FILE}" up -d amneziawg >/dev/null
else
  docker start vpn-amneziawg >/dev/null 2>&1 || true
fi

if [[ "${rebuilt}" -eq 1 ]]; then
  log_info "amneziawg module rebuilt and vpn-amneziawg restarted."
else
  log_error "amneziawg module rebuild failed after 3 attempts — container restarted to keep retrying."
  exit 1
fi
