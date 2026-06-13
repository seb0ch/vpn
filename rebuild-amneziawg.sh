#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

if [[ "${EUID}" -ne 0 ]]; then
  log_error "Run as root: sudo $0"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  log_error "Docker is not installed."
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  log_error "Cannot detect OS — /etc/os-release not found."
  exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
  log_error "Unsupported OS: ${ID}. Only Ubuntu is supported."
  exit 1
fi

UBUNTU_VERSION="${VERSION_ID}"
UBUNTU_CODENAME="${VERSION_CODENAME:-}"
if [[ -z "${UBUNTU_CODENAME}" ]]; then
  log_error "VERSION_CODENAME missing from /etc/os-release. Set UBUNTU_CODENAME explicitly and re-run."
  exit 1
fi
KERNEL_VERSION="$(uname -r)"

# Override the APT mirror used inside the builder container by exporting
# APT_MIRROR / APT_SECURITY_MIRROR before invoking this script.
APT_MIRROR="${APT_MIRROR:-http://mirrors.edge.kernel.org/ubuntu}"
APT_SECURITY_MIRROR="${APT_SECURITY_MIRROR:-http://security.ubuntu.com/ubuntu}"

KMOD_DIR="/lib/modules/${KERNEL_VERSION}/extra"
# Keep backups outside /lib/modules so depmod never has to consider them.
BACKUP_DIR="/var/backups/amneziawg-kmod/${KERNEL_VERSION}"
MODULE_PATH="${KMOD_DIR}/amneziawg.ko"
IMAGE_NAME="amneziawg-kmod-builder:${KERNEL_VERSION}"
BUILD_CTX="$(mktemp -d)"
CID=""

cleanup() {
  rm -rf "${BUILD_CTX}"
  if [[ -n "${CID}" ]]; then
    docker rm "${CID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Persist module loading across host reboots; without this the container
# cannot recover after a reboot because it has no CAP_SYS_MODULE. Idempotent
# and independent of which module ends up loaded, so it is safe to call from
# both the normal success path and the rollback-success path.
persist_module_autoload() {
  if [[ ! -f /etc/modules-load.d/amneziawg.conf ]]; then
    echo amneziawg > /etc/modules-load.d/amneziawg.conf
    log_info "Persisted module autoload: /etc/modules-load.d/amneziawg.conf"
  fi
}

log_info "Ubuntu version: ${UBUNTU_VERSION}"
log_info "Ubuntu codename: ${UBUNTU_CODENAME}"
log_info "Kernel version: ${KERNEL_VERSION}"
log_info "Module path: ${MODULE_PATH}"

# Refuse to operate while the amneziawg container is up — its bind-mount on
# /lib/modules and an active awg0 inside its netns would leave the host in
# an undefined state if we swap the .ko underneath it.
if docker ps --format '{{.Names}}' | grep -qx amneziawg; then
  log_error "Container 'amneziawg' is running. Stop it first:"
  log_error "  docker compose stop amneziawg"
  exit 1
fi

log_info "Checking if amneziawg module is currently loaded..."

if lsmod | awk '{print $1}' | grep -qx amneziawg; then
  log_info "amneziawg is loaded. Trying to unload it..."

  if ! modprobe -r amneziawg; then
    log_error "Failed to unload amneziawg module."
    log_error "Stop AmneziaWG/WireGuard interfaces or containers first, then retry."
    log_error ""
    log_error "Examples:"
    log_error "  docker compose stop amneziawg"
    log_error "  ip link delete awg0"
    exit 1
  fi
else
  log_info "amneziawg module is not loaded."
fi

mkdir -p "${KMOD_DIR}" "${BACKUP_DIR}"

BACKUP_PATH=""
if [[ -f "${MODULE_PATH}" ]]; then
  BACKUP_PATH="${BACKUP_DIR}/amneziawg.ko.$(date +%Y%m%d-%H%M%S)"
  log_info "Backing up existing module:"
  log_info "  ${MODULE_PATH}"
  log_info "  -> ${BACKUP_PATH}"
  # Atomic backup: copy to .partial, then rename. Avoids a half-written
  # backup being picked up as "newest" by the rotation step below.
  cp -a "${MODULE_PATH}" "${BACKUP_PATH}.partial"
  mv -f "${BACKUP_PATH}.partial" "${BACKUP_PATH}"

  # Keep the 3 most recent backups; drop the rest. Filename has only digits
  # and `-`, so word-splitting from `ls` is safe here.
  # shellcheck disable=SC2012
  ls -1t "${BACKUP_DIR}"/amneziawg.ko.* 2>/dev/null | tail -n +4 | xargs -r rm -f
fi

log_info "Creating Docker build context..."

cat > "${BUILD_CTX}/Dockerfile" <<EOF
FROM ubuntu:${UBUNTU_VERSION}

RUN rm -f /etc/apt/sources.list.d/ubuntu.sources && \\
cat > /etc/apt/sources.list.d/ubuntu.sources <<APT_SOURCES
Types: deb
URIs: ${APT_MIRROR}
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${APT_SECURITY_MIRROR}
Suites: ${UBUNTU_CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
APT_SOURCES

RUN apt-get clean && \\
    apt-get update && \\
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      ca-certificates \\
      git \\
      make \\
      gcc \\
      kmod \\
      linux-headers-${KERNEL_VERSION} && \\
    update-ca-certificates && \\
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module /src/awg-module

WORKDIR /src/awg-module/src

RUN make -C /lib/modules/${KERNEL_VERSION}/build M=\$(pwd) modules
EOF

log_info "Building kernel module inside Docker..."
docker build --no-cache -t "${IMAGE_NAME}" "${BUILD_CTX}"

log_info "Extracting amneziawg.ko from builder image..."

CID="$(docker create "${IMAGE_NAME}")"

# Atomic install: write to a sibling staging file, sanity-check, then rename.
# Avoids leaving a corrupt .ko in place if `docker cp` is interrupted mid-stream.
# The suffix must remain `.ko` because kmod's modinfo selects path-vs-module-name
# by extension; a name like `amneziawg.ko.new` ends in `.new` and gets looked up
# as a module name instead, falsely failing the sanity check below.
NEW_PATH="${KMOD_DIR}/amneziawg.new.ko"
docker cp "${CID}:/src/awg-module/src/amneziawg.ko" "${NEW_PATH}"

# Drop the builder container immediately so docker rmi below succeeds without
# warnings; the trap still runs but turns into a harmless no-op.
docker rm "${CID}" >/dev/null
CID=""

if [[ ! -s "${NEW_PATH}" ]]; then
  rm -f "${NEW_PATH}"
  log_error "Extracted amneziawg.ko is empty — aborting."
  exit 1
fi
if ! modinfo "${NEW_PATH}" >/dev/null 2>&1; then
  rm -f "${NEW_PATH}"
  log_error "Extracted amneziawg.ko fails modinfo — aborting."
  exit 1
fi
chmod 0644 "${NEW_PATH}"
mv -f "${NEW_PATH}" "${MODULE_PATH}"

log_info "Running depmod..."
depmod -a "${KERNEL_VERSION}"

log_info "Loading rebuilt amneziawg module..."
if ! modprobe amneziawg; then
  log_error "modprobe amneziawg failed — the new module is on disk but not loaded."
  if [[ -n "${BACKUP_PATH}" && -f "${BACKUP_PATH}" ]]; then
    # Verify the backup matches the running kernel before restoring. A backup
    # built for a previous kernel would also fail to load, leaving the
    # operator no better off than before the rollback.
    BACKUP_VERMAGIC="$(modinfo -F vermagic "${BACKUP_PATH}" 2>/dev/null | awk '{print $1}')"
    if [[ "${BACKUP_VERMAGIC}" != "${KERNEL_VERSION}" ]]; then
      log_error "Refusing to roll back: backup vermagic '${BACKUP_VERMAGIC}' does not match running kernel '${KERNEL_VERSION}'."
      log_error "  Backup: ${BACKUP_PATH}"
      log_error "  Restore manually only if you understand the mismatch."
      exit 1
    fi
    log_warn "Rolling back to previous module: ${BACKUP_PATH}"
    cp -a "${BACKUP_PATH}" "${MODULE_PATH}"
    depmod -a "${KERNEL_VERSION}"
    if modprobe amneziawg; then
      log_warn "Previous module restored and loaded successfully."
      # The rolled-back module is loaded and valid for this kernel; persist
      # autoload so a reboot before the next rebuild does not crash-loop the
      # capability-less container.
      persist_module_autoload
    else
      log_error "Rollback also failed — manual intervention required."
      log_error "  Previous module backups: ${BACKUP_DIR}/"
    fi
  else
    log_error "No backup available for rollback (this was the first install)."
  fi
  exit 1
fi

persist_module_autoload

log_info "Cleaning Docker image..."
docker rmi "${IMAGE_NAME}" >/dev/null || log_warn "Could not remove builder image ${IMAGE_NAME}"

log_info "Done."
echo
# `sed` reads the full stream, so we never SIGPIPE modinfo (`modinfo | head`
# would, and with `pipefail` that aborts the script after a successful build).
# Read by file path, not name, so we report what we just installed even if a
# higher-priority directory (e.g. updates/) shadows the module name.
modinfo "${MODULE_PATH}" | sed -n '1,30p'
