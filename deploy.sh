#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── 1. Enable IP forwarding on the host ──────────────────────────────────────
if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
  log_info "Enabling IP forwarding…"
  sysctl -w net.ipv4.ip_forward=1
fi
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  log_info "Made IP forwarding persistent in /etc/sysctl.conf"
fi

# ── 2. Verify Docker is installed ────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  log_error "Docker is not installed. Please install Docker and Docker Compose first."
  exit 1
fi

if ! docker compose version &>/dev/null; then
  log_error "Docker Compose is not installed. Please install Docker Compose first."
  exit 1
fi

log_info "Docker: $(docker --version)"
log_info "Docker Compose: $(docker compose version)"
echo ""

# ── 2b. Host INPUT hardening ─────────────────────────────────────────────────
# VPN-client traffic leaves the amneziawg container MASQUERADEd as an address
# in 172.20.0.0/24; without this rule it can reach host-local services (sshd
# on the public IP included) without ever traversing the cloud firewall.
# NEW-only: replies to host-initiated connections to containers still flow.
if ! iptables -C INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP 2>/dev/null; then
  iptables -I INPUT 1 -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP
  log_info "Host INPUT rule installed (block NEW from 172.20.0.0/24)."
fi

cat > /etc/systemd/system/vpn-host-firewall.service <<'UNIT'
[Unit]
Description=Block new connections from the VPN docker subnet to the host
After=network-pre.target
Before=network.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/iptables -C INPUT -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP 2>/dev/null || /usr/sbin/iptables -I INPUT 1 -s 172.20.0.0/24 -m conntrack --ctstate NEW -j DROP'

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable vpn-host-firewall.service >/dev/null
log_info "Host INPUT rule persisted via vpn-host-firewall.service."
echo ""

# ── 3. Build and install AmneziaWG kernel module ────────────────────────────
if lsmod | grep -q '^amneziawg'; then
  log_info "AmneziaWG kernel module already loaded — skipping."
elif modprobe amneziawg 2>/dev/null; then
  log_info "AmneziaWG kernel module loaded from existing install."
else
  log_info "Building AmneziaWG kernel module in Docker…"

  # Detect Ubuntu version and kernel
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
  UBUNTU_VERSION="${VERSION_ID}"       # e.g. "22.04"
  KERNEL_VERSION="$(uname -r)"        # e.g. "5.15.0-91-generic"

  log_info "OS: Ubuntu ${UBUNTU_VERSION}, kernel: ${KERNEL_VERSION}"

  # Build the .ko inside a matching Ubuntu container with kernel headers
  KMOD_DIR="/lib/modules/${KERNEL_VERSION}/extra"
  mkdir -p "${KMOD_DIR}"

  BUILD_CTX=$(mktemp -d)

  docker build --no-cache -t amneziawg-kmod-builder -f - "${BUILD_CTX}" <<DOCKERFILE
FROM ubuntu:${UBUNTU_VERSION}
RUN apt-get update -qq && \\
    apt-get install -y -qq --no-install-recommends \\
      git make gcc linux-headers-${KERNEL_VERSION} ca-certificates && \\
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module /src/awg-module
WORKDIR /src/awg-module/src
RUN make -C /lib/modules/${KERNEL_VERSION}/build M=\$(pwd) modules
DOCKERFILE

  rm -rf "${BUILD_CTX}"

  # Copy the built module out of the builder container
  docker run --rm amneziawg-kmod-builder \
    cat /src/awg-module/src/amneziawg.ko > "${KMOD_DIR}/amneziawg.ko"

  # Clean up builder image
  docker rmi amneziawg-kmod-builder >/dev/null 2>&1 || true

  # Register and load the module
  depmod -a "${KERNEL_VERSION}"
  modprobe amneziawg

  log_info "AmneziaWG kernel module built and loaded."
fi
echo ""

# ── 4. Build Docker images ───────────────────────────────────────────────────
log_info "Building Docker images…"
docker build -t amneziawg ./amneziawg
docker build -t xray      ./xray
docker build -t dns       ./dns

# ── 5. AmneziaWG keys ────────────────────────────────────────────────────────
if [[ ! -f amneziawg/conf/server_private.key ]]; then
  log_info "Generating AmneziaWG server keys…"
  ./amneziawg/gen-keys.sh
else
  log_info "AmneziaWG keys already exist — skipping."
  log_info "(Delete amneziawg/conf/server_private.key to regenerate.)"
fi

# ── 6. docker-compose.yml ────────────────────────────────────────────────────
AWG_PORT=$(grep "^ListenPort" amneziawg/conf/awg0.conf | awk '{print $3}')
if [[ -z "${AWG_PORT}" ]]; then
  log_error "Could not read ListenPort from amneziawg/conf/awg0.conf"
  exit 1
fi
sed "s/AWG_PORT/${AWG_PORT}/g" docker-compose.yml.tmpl > docker-compose.yml
log_info "Generated docker-compose.yml (AWG port ${AWG_PORT})"

# ── 7. Xray keys ─────────────────────────────────────────────────────────────
if [[ ! -f xray/conf/reality_keys.txt ]]; then
  log_info "Generating Xray REALITY keys…"
  ./xray/gen-keys.sh
else
  log_info "Xray keys already exist — skipping."
  log_info "(Delete xray/conf/reality_keys.txt to regenerate.)"
fi

# ── 8. Start services ────────────────────────────────────────────────────────
log_info "Starting services…"
docker compose up -d

echo ""
log_info "Deployment complete."
echo ""

mkdir -p clients
# Extract the host-side port (first number before the colon in the udp mapping)
AWG_UDP_PORT=$(grep -Eo '[0-9]+:[0-9]+/udp' docker-compose.yml | head -1 | cut -d: -f1)
echo "Open these ports on your cloud firewall (AWS Security Group, GCP VPC, etc.):"
printf "  %-14s — AmneziaWG\n"    "${AWG_UDP_PORT}/udp"
printf "  %-14s — Xray REALITY\n" "443/tcp"
echo ""
echo "Add your first client:"
echo "  ./add-client.sh <name>"
