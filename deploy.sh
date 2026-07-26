#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"

# ── 1. Enable IP forwarding on the host ──────────────────────────────────────
if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
  log_info "Enabling IP forwarding…"
  sysctl -w net.ipv4.ip_forward=1
fi
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  log_info "Made IP forwarding persistent in /etc/sysctl.conf"
fi

# ── 1b. Size the conntrack table for the VPN hub role ────────────────────────
# This host NATs many AmneziaWG peers and — when it is an entry/hub — Xray also
# proxies each client's flows out to other servers; every flow consumes
# conntrack entries. On low-RAM VPSes the kernel default (~4096) overflows under
# load, and a full table doesn't just drop packets: the kernel returns EPERM
# ("operation not permitted") on new locally-originated connections, which
# silently breaks Xray cross-server routing and DNS. Size it up persistently.
#
# Load nf_conntrack now — both to read the kernel's current limits below and to
# persist the load ordered *before* systemd-sysctl on every boot. Without that,
# the net.netfilter.* keys don't exist yet when systemd-sysctl runs, so the
# drop-in is skipped and the limits silently revert to the kernel default until
# something else loads the module.
modprobe nf_conntrack 2>/dev/null || true
echo nf_conntrack > /etc/modules-load.d/vpn-conntrack.conf

# Size UP only. Big-RAM kernels already default higher (262144 is common); pick
# the larger of our floor and whatever the kernel currently uses so a deploy
# never shrinks an existing table (which would REDUCE capacity).
CT_MAX_FLOOR=32768
CT_HASH_FLOOR=8192
cur_max="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)"
cur_hash="$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo 0)"
[[ "${cur_max}"  =~ ^[0-9]+$ ]] || cur_max=0
[[ "${cur_hash}" =~ ^[0-9]+$ ]] || cur_hash=0
CT_MAX=$(( cur_max  > CT_MAX_FLOOR  ? cur_max  : CT_MAX_FLOOR  ))
CT_HASH=$(( cur_hash > CT_HASH_FLOOR ? cur_hash : CT_HASH_FLOOR ))

cat > /etc/sysctl.d/99-vpn-conntrack.conf <<CONF
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
CONF
# Bucket count is fixed at module-load time; sysctl only sizes nf_conntrack_max.
cat > /etc/modprobe.d/vpn-conntrack.conf <<CONF
options nf_conntrack hashsize=${CT_HASH}
CONF

# Apply live too (best-effort; the files above are what persists across reboots).
if [[ -d /proc/sys/net/netfilter ]]; then
  sysctl -q -p /etc/sysctl.d/99-vpn-conntrack.conf || true
  if [[ -w /sys/module/nf_conntrack/parameters/hashsize && "${CT_HASH}" -gt "${cur_hash}" ]]; then
    echo "${CT_HASH}" > /sys/module/nf_conntrack/parameters/hashsize || true
  fi
fi
log_info "Conntrack table sized for the hub role (nf_conntrack_max=${CT_MAX})."
echo ""

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
# A oneshot unit owns the rule so it survives reboots; `enable --now` installs
# it immediately and arms it for boot — a single source of truth instead of a
# separate runtime `iptables -I` that could drift from the unit.
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
systemctl enable --now vpn-host-firewall.service >/dev/null
log_info "Host INPUT rule installed and persisted via vpn-host-firewall.service."
echo ""

# ── 2c. Resolve third-party component versions ──────────────────────────────
# Every deploy/re-deploy resolves each component to a release tag — its
# *_RELEASE env var if set, otherwise the latest upstream release — and pins it
# to a commit SHA. Images are TAGGED with the release (xray:<ver>, …); sources
# are FETCHED by SHA, so a moved tag can't change a build. See lib/versions.sh.
log_info "Resolving component versions…"

# Reject a malformed *_RELEASE up front. Without this, an invalid value (e.g.
# containing '/') would make resolve_ref fail and be indistinguishable from a
# tag that simply doesn't exist — the AmneziaWG branch would then silently fall
# back to "latest" instead of telling the operator their pin is wrong.
for _rel in XRAY_RELEASE AMNEZIAWG_RELEASE DNSCRYPT_RELEASE; do
  _val="${!_rel:-}"
  if [[ -n "${_val}" ]] && ! valid_docker_tag "${_val}"; then
    log_error "${_rel}='${_val}' is not a valid release tag."
    exit 1
  fi
done
unset _rel _val

# resolve_into <tag_var> <sha_var> <name> <repo> <env_value>
# Sets the two named globals; aborts the script on failure (note: must run in
# the current shell, never inside $(), so its exit propagates).
resolve_into() {
  local out
  if ! out="$(resolve_ref "$4" "$5")"; then
    log_error "Could not resolve a release for $3 (network issue or no matching tag?)."
    exit 1
  fi
  printf -v "$1" '%s' "${out%%$'\t'*}"
  printf -v "$2" '%s' "${out##*$'\t'}"
}

resolve_into XRAY_TAG     XRAY_SHA     "Xray"           "${REPO_XRAY}"     "${XRAY_RELEASE:-}"
resolve_into DNSCRYPT_TAG DNSCRYPT_SHA "dnscrypt-proxy" "${REPO_DNSCRYPT}" "${DNSCRYPT_RELEASE:-}"

# AmneziaWG userspace tools — this is what the `amneziawg` IMAGE contains, so it
# is what the image is tagged with. AMNEZIAWG_RELEASE pins it; if the tools repo
# has no such tag, fall back to the tools' own latest. (The kernel MODULE is a
# host artifact resolved separately in section 3, only when it is actually built,
# so a re-deploy doesn't need network to resolve a module it won't rebuild.)
if [[ -n "${AMNEZIAWG_RELEASE:-}" ]]; then
  if AWG_TOOLS_OUT="$(resolve_ref "${REPO_AWG_TOOLS}" "${AMNEZIAWG_RELEASE}")"; then
    IFS=$'\t' read -r AWG_TOOLS_TAG AWG_TOOLS_SHA <<<"${AWG_TOOLS_OUT}"
  else
    log_warn "amneziawg-tools has no tag '${AMNEZIAWG_RELEASE}' — using its latest."
    resolve_into AWG_TOOLS_TAG AWG_TOOLS_SHA "amneziawg-tools" "${REPO_AWG_TOOLS}" ""
  fi
else
  resolve_into AWG_TOOLS_TAG AWG_TOOLS_SHA "amneziawg-tools" "${REPO_AWG_TOOLS}" ""
fi

log_info "  xray            ${XRAY_TAG}"
log_info "  amneziawg-tools ${AWG_TOOLS_TAG} (image tag)"
log_info "  dnscrypt-proxy  ${DNSCRYPT_TAG}"
echo ""

# ── 3. Build and install AmneziaWG kernel module ────────────────────────────
if grep -q '^amneziawg ' /proc/modules; then
  log_info "AmneziaWG kernel module already loaded — skipping build."
  log_info "(To move to a newer module release, run rebuild-amneziawg.sh.)"
elif modprobe amneziawg 2>/dev/null; then
  log_info "AmneziaWG kernel module loaded from existing install."
  log_info "(To move to a newer module release, run rebuild-amneziawg.sh.)"
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

  # Resolve the kernel-module release only now that we know we must build it
  # (AMNEZIAWG_RELEASE or the module repo's latest), pinned to its commit SHA.
  resolve_into AWG_KMOD_TAG AWG_KMOD_SHA "AmneziaWG kernel module" "${REPO_AWG_KMOD}" "${AMNEZIAWG_RELEASE:-}"
  log_info "AmneziaWG module release: ${AWG_KMOD_TAG} (${AWG_KMOD_SHA})"

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
RUN git init /src/awg-module && \\
    git -C /src/awg-module remote add origin https://github.com/amnezia-vpn/amneziawg-linux-kernel-module && \\
    git -C /src/awg-module fetch --depth 1 origin ${AWG_KMOD_SHA} && \\
    git -C /src/awg-module checkout --detach FETCH_HEAD
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

# Persist module loading across host reboots; without this the container
# cannot recover after a reboot once CAP_SYS_MODULE is dropped.
if [[ ! -f /etc/modules-load.d/amneziawg.conf ]]; then
  echo amneziawg > /etc/modules-load.d/amneziawg.conf
  log_info "Persisted module autoload: /etc/modules-load.d/amneziawg.conf"
fi
echo ""

# ── 4. Build Docker images ───────────────────────────────────────────────────
# Each image is tagged with its component release; sources are fetched by the
# resolved commit SHA passed as a build-arg. The xray build gets a per-deploy
# GEO_BUST nonce so the (unpinned) geo databases are always re-pulled fresh.
log_info "Building Docker images…"
docker build --build-arg AWG_TOOLS_REF="${AWG_TOOLS_SHA}" -t "amneziawg:${AWG_TOOLS_TAG}" ./amneziawg
docker build --build-arg XRAY_REF="${XRAY_SHA}" --build-arg GEO_BUST="$(date +%s)" -t "xray:${XRAY_TAG}" ./xray
docker build --build-arg DNSCRYPT_REF="${DNSCRYPT_SHA}"   -t "dns:${DNSCRYPT_TAG}"        ./dns

# ── 5. AmneziaWG keys ────────────────────────────────────────────────────────
if [[ ! -f amneziawg/conf/server_private.key ]]; then
  log_info "Generating AmneziaWG server keys…"
  AMNEZIAWG_IMAGE="amneziawg:${AWG_TOOLS_TAG}" ./amneziawg/gen-keys.sh
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
sed -e "s/AWG_PORT/${AWG_PORT}/g" \
    -e "s/__AWG_TAG__/${AWG_TOOLS_TAG}/g" \
    -e "s/__XRAY_TAG__/${XRAY_TAG}/g" \
    -e "s/__DNS_TAG__/${DNSCRYPT_TAG}/g" \
    docker-compose.yml.tmpl > docker-compose.yml
log_info "Generated docker-compose.yml (AWG port ${AWG_PORT})"

# ── 7. Xray keys ─────────────────────────────────────────────────────────────
if [[ ! -f xray/conf/reality_keys.txt ]]; then
  log_info "Generating Xray REALITY keys…"
  XRAY_IMAGE="xray:${XRAY_TAG}" ./xray/gen-keys.sh
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
chmod 700 clients
# Extract the host-side port (first number before the colon in the udp mapping)
AWG_UDP_PORT=$(grep -Eo '[0-9]+:[0-9]+/udp' docker-compose.yml | head -1 | cut -d: -f1)
echo "Open these ports on your cloud firewall (AWS Security Group, GCP VPC, etc.):"
printf "  %-14s — AmneziaWG\n"    "${AWG_UDP_PORT}/udp"
printf "  %-14s — Xray REALITY\n" "443/tcp"
echo ""
echo "Add your first client:"
echo "  ./add-client.sh <name>"
