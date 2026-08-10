#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"

# ── 0. Component selection ───────────────────────────────────────────────────
# Both client-facing components are deployed by default; either can be switched
# off for a single-protocol host by exporting ENABLE_AMNEZIAWG=0 or ENABLE_XRAY=0.
# Only what is enabled gets built, keyed, and rendered into docker-compose.yml.
#
# The dns service follows AmneziaWG rather than having a flag of its own: only
# AWG clients are DNAT'ed to it (see awg0.tmpl), while Xray resolves through the
# public servers configured in its own config.json. An Xray-only host therefore
# runs a single container.
for _flag in ENABLE_AMNEZIAWG ENABLE_XRAY; do
  if ! _val="$(parse_bool "${!_flag:-}" 1)"; then
    log_error "${_flag}='${!_flag}' is not a boolean — use 1/0, true/false, yes/no, or on/off."
    exit 1
  fi
  printf -v "${_flag}" '%s' "${_val}"
done
unset _flag _val

if [[ "${ENABLE_AMNEZIAWG}" == "0" && "${ENABLE_XRAY}" == "0" ]]; then
  log_error "ENABLE_AMNEZIAWG=0 and ENABLE_XRAY=0 leave nothing to deploy."
  log_error "Enable at least one component, or run cleanup.sh to tear the stack down."
  exit 1
fi

log_info "Components: AmneziaWG $([[ "${ENABLE_AMNEZIAWG}" == "1" ]] && echo enabled || echo DISABLED), Xray $([[ "${ENABLE_XRAY}" == "1" ]] && echo enabled || echo DISABLED), dns $([[ "${ENABLE_AMNEZIAWG}" == "1" ]] && echo enabled || echo "DISABLED (follows AmneziaWG)")"
echo ""

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

XRAY_TAG=""; XRAY_SHA=""
AWG_TOOLS_TAG=""; AWG_TOOLS_SHA=""
DNSCRYPT_TAG=""; DNSCRYPT_SHA=""

if [[ "${ENABLE_XRAY}" == "1" ]]; then
  resolve_into XRAY_TAG XRAY_SHA "Xray" "${REPO_XRAY}" "${XRAY_RELEASE:-}"
fi
# dnscrypt-proxy is only deployed alongside AmneziaWG (see section 0).
if [[ "${ENABLE_AMNEZIAWG}" == "1" ]]; then
  resolve_into DNSCRYPT_TAG DNSCRYPT_SHA "dnscrypt-proxy" "${REPO_DNSCRYPT}" "${DNSCRYPT_RELEASE:-}"
fi

# AmneziaWG userspace tools — this is what the `amneziawg` IMAGE contains, so it
# is what the image is tagged with. AMNEZIAWG_RELEASE pins it; if the tools repo
# has no such tag, fall back to the tools' own latest. (The kernel MODULE is a
# host artifact resolved separately in section 3, only when it is actually built,
# so a re-deploy doesn't need network to resolve a module it won't rebuild.)
if [[ "${ENABLE_AMNEZIAWG}" == "1" ]]; then
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
fi

[[ "${ENABLE_XRAY}" == "1" ]]      && log_info "  xray            ${XRAY_TAG}"
[[ "${ENABLE_AMNEZIAWG}" == "1" ]] && log_info "  amneziawg-tools ${AWG_TOOLS_TAG} (image tag)"
[[ "${ENABLE_AMNEZIAWG}" == "1" ]] && log_info "  dnscrypt-proxy  ${DNSCRYPT_TAG}"
echo ""

# ── 3. Build and install AmneziaWG kernel module ────────────────────────────
if [[ "${ENABLE_AMNEZIAWG}" == "0" ]]; then
  # Only skip the build here. The host-level AmneziaWG bits (boot unit,
  # modules-load.d) are torn down in section 9, after the new state is actually
  # running: a build or start failure in between would otherwise leave the old
  # container deployed but unable to load its module after a reboot.
  log_info "AmneziaWG disabled (ENABLE_AMNEZIAWG=0) — skipping module and container."
  echo ""
elif grep -q '^amneziawg ' /proc/modules; then
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
if [[ "${ENABLE_AMNEZIAWG}" == "1" && ! -f /etc/modules-load.d/amneziawg.conf ]]; then
  echo amneziawg > /etc/modules-load.d/amneziawg.conf
  log_info "Persisted module autoload: /etc/modules-load.d/amneziawg.conf"
fi

# ── 3b. Rebuild the module after a kernel upgrade ────────────────────────────
# modules-load.d only *loads* an existing .ko; it cannot help after a kernel
# upgrade (unattended-upgrades) + reboot, when no module was ever built for the
# new kernel and there is no DKMS. The capability-less container then crash-
# loops. This oneshot runs on boot after docker and, when the module is missing
# for the running kernel, rebuilds it (stopping/starting the container around
# the build). At deploy time the module already exists, so it is a no-op.
#
# Capture any operator release pin into the unit so a boot rebuild installs the
# SAME module release this deploy used, not whatever is latest at the next
# kernel upgrade. Empty when unpinned — rebuild-amneziawg.sh then tracks latest,
# matching this deploy's own behaviour.
# The whole block below is guarded; its body stays at column 0 so the unit
# heredoc keeps reading exactly as it is written to disk.
if [[ "${ENABLE_AMNEZIAWG}" == "1" ]]; then
AWG_RELEASE_ENV=""
if [[ -n "${AMNEZIAWG_RELEASE:-}" ]]; then
  AWG_RELEASE_ENV="Environment=AMNEZIAWG_RELEASE=${AMNEZIAWG_RELEASE}"
fi
cat > /etc/systemd/system/amneziawg-module.service <<UNIT
[Unit]
Description=Ensure the AmneziaWG kernel module matches the running kernel
# network-online.target: a rebuild fetches sources from GitHub and APT mirrors,
# so ordering after it avoids failing on a not-yet-ready network at early boot.
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
${AWG_RELEASE_ENV}
ExecStart=${SCRIPT_DIR}/ensure-amneziawg-module.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable amneziawg-module.service >/dev/null
log_info "Installed amneziawg-module.service (rebuilds the module after kernel upgrades)."
echo ""
fi

# ── 4. Build Docker images ───────────────────────────────────────────────────
# Each image is tagged with its component release; sources are fetched by the
# resolved commit SHA passed as a build-arg. The xray build gets a per-deploy
# GEO_BUST nonce so the (unpinned) geo databases are always re-pulled fresh.
log_info "Building Docker images…"
if [[ "${ENABLE_AMNEZIAWG}" == "1" ]]; then
  docker build --build-arg AWG_TOOLS_REF="${AWG_TOOLS_SHA}" -t "amneziawg:${AWG_TOOLS_TAG}" ./amneziawg
fi
if [[ "${ENABLE_XRAY}" == "1" ]]; then
  docker build --build-arg XRAY_REF="${XRAY_SHA}" --build-arg GEO_BUST="$(date +%s)" -t "xray:${XRAY_TAG}" ./xray
fi
if [[ "${ENABLE_AMNEZIAWG}" == "1" ]]; then
  docker build --build-arg DNSCRYPT_REF="${DNSCRYPT_SHA}" -t "dns:${DNSCRYPT_TAG}" ./dns
fi

# ── 5. AmneziaWG keys ────────────────────────────────────────────────────────
AWG_PORT=""
if [[ "${ENABLE_AMNEZIAWG}" == "1" ]]; then
  if [[ ! -f amneziawg/conf/server_private.key ]]; then
    log_info "Generating AmneziaWG server keys…"
    AMNEZIAWG_IMAGE="amneziawg:${AWG_TOOLS_TAG}" ./amneziawg/gen-keys.sh
  else
    log_info "AmneziaWG keys already exist — skipping."
    log_info "(Delete amneziawg/conf/server_private.key to regenerate.)"
  fi

  AWG_PORT=$(grep "^ListenPort" amneziawg/conf/awg0.conf | awk '{print $3}')
  if [[ -z "${AWG_PORT}" ]]; then
    log_error "Could not read ListenPort from amneziawg/conf/awg0.conf"
    exit 1
  fi
fi

# ── 6. docker-compose.yml ────────────────────────────────────────────────────
# Disabled components are dropped from the rendered file, which then becomes the
# source of truth for what is deployed (add-client.sh and friends read it).
#
# It is rendered to a staging path and only published once the new state is
# actually running (section 8). A half-finished deploy must never leave a
# docker-compose.yml that claims a component is gone while its container is
# still up — remove-client.sh trusts this file and would skip revoking a live
# credential.
DISABLED_SERVICES=""
# dns goes with amneziawg — and so does every fragment marked `needs: dns`,
# such as the xray service's depends_on.
[[ "${ENABLE_AMNEZIAWG}" == "0" ]] && DISABLED_SERVICES="amneziawg,dns"
[[ "${ENABLE_XRAY}"      == "0" ]] && DISABLED_SERVICES="${DISABLED_SERVICES}${DISABLED_SERVICES:+,}xray"

COMPOSE_STAGED="docker-compose.yml.new"
trap 'rm -f "${SCRIPT_DIR}/${COMPOSE_STAGED}"' EXIT

render_compose docker-compose.yml.tmpl "${DISABLED_SERVICES}" \
  | sed -e "s/AWG_PORT/${AWG_PORT}/g" \
        -e "s/__AWG_TAG__/${AWG_TOOLS_TAG}/g" \
        -e "s/__XRAY_TAG__/${XRAY_TAG}/g" \
        -e "s/__DNS_TAG__/${DNSCRYPT_TAG}/g" \
  > "${COMPOSE_STAGED}"
log_info "Rendered docker-compose.yml${AWG_PORT:+ (AWG port ${AWG_PORT})}"

# ── 7. Xray keys ─────────────────────────────────────────────────────────────
if [[ "${ENABLE_XRAY}" == "1" ]]; then
  if [[ ! -f xray/conf/reality_keys.txt ]]; then
    log_info "Generating Xray REALITY keys…"
    XRAY_IMAGE="xray:${XRAY_TAG}" ./xray/gen-keys.sh
  else
    log_info "Xray keys already exist — skipping."
    log_info "(Delete xray/conf/reality_keys.txt to regenerate.)"
  fi
fi

# ── 8. Start services ────────────────────────────────────────────────────────
# Converge against the staged file first: --remove-orphans drops the container
# of a component this deploy turned off (without it a disabled service would
# keep running from the previous run). Only once that succeeded is the file
# published as docker-compose.yml — so the on-disk description of the host
# never runs ahead of what is actually deployed.
log_info "Starting services…"
docker compose -f "${COMPOSE_STAGED}" up -d --remove-orphans
mv -f "${COMPOSE_STAGED}" docker-compose.yml
log_info "Published docker-compose.yml"

# ── 9. Retire host artifacts of disabled components ──────────────────────────
# Now that the AmneziaWG container is confirmed gone, drop the host-level bits a
# previous deploy installed, so no reboot loads or rebuilds a module nothing
# uses. Keys, awg0.conf, and client files are deliberately left in place: they
# are secrets this script must not destroy, and re-enabling restores the same
# peers. Use cleanup.sh to erase them.
if [[ "${ENABLE_AMNEZIAWG}" == "0" ]]; then
  if [[ -f /etc/systemd/system/amneziawg-module.service ]]; then
    systemctl disable --now amneziawg-module.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/amneziawg-module.service
    systemctl daemon-reload
    log_info "Removed amneziawg-module.service (AmneziaWG is disabled)."
  fi
  if [[ -f /etc/modules-load.d/amneziawg.conf ]]; then
    rm -f /etc/modules-load.d/amneziawg.conf
    log_info "Removed /etc/modules-load.d/amneziawg.conf (module stays loaded until reboot)."
  fi
fi

echo ""
log_info "Deployment complete."
echo ""

mkdir -p clients
chmod 700 clients
echo "Open these ports on your cloud firewall (AWS Security Group, GCP VPC, etc.):"
if [[ "${ENABLE_AMNEZIAWG}" == "1" ]]; then
  # Extract the host-side port (first number before the colon in the udp mapping)
  AWG_UDP_PORT=$(grep -Eo '[0-9]+:[0-9]+/udp' docker-compose.yml | head -1 | cut -d: -f1)
  printf "  %-14s — AmneziaWG\n" "${AWG_UDP_PORT}/udp"
fi
if [[ "${ENABLE_XRAY}" == "1" ]]; then
  printf "  %-14s — Xray REALITY\n" "443/tcp"
fi
echo ""
echo "Add your first client:"
echo "  ./add-client.sh <name>"
