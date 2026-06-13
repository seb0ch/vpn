#!/usr/bin/env bash
set -euo pipefail

# Docker + Docker Compose plugin installer for Ubuntu 24.04+
#
# Installs everything from Ubuntu's own repositories (the `universe` component,
# enabled by default) — NO third-party apt repo or GPG key is added. The
# packages used:
#   - docker.io          Docker Engine + CLI (universe)
#   - docker-compose-v2  the `docker compose` subcommand plugin (universe)
#   - docker-buildx      the `docker buildx` builder plugin (universe)
# docker.io pulls Ubuntu's `containerd` (in main) as its runtime dependency.
#
# Skips installation if already present.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Run this script as root or with sudo."
fi

# ── OS check ──────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  if [[ "${ID}" != "ubuntu" ]]; then
    error "This script targets Ubuntu. Detected: ${ID}"
  fi
  if [[ "$(echo "${VERSION_ID} 24.04" | awk '{print ($1 < $2)}')" == "1" ]]; then
    error "Ubuntu 24.04 or higher required. Detected: ${VERSION_ID}"
  fi
else
  error "/etc/os-release not found. Cannot verify OS."
fi

# ── check existing installations ──────────────────────────────────────────────
DOCKER_OK=false
COMPOSE_OK=false
BUILDX_OK=false

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version)
  info "Docker already installed: ${DOCKER_VER}"
  DOCKER_OK=true
fi

if docker compose version &>/dev/null 2>&1; then
  COMPOSE_VER=$(docker compose version)
  info "Docker Compose plugin already installed: ${COMPOSE_VER}"
  COMPOSE_OK=true
fi

# buildx is required for the from-source image builds (xray/gVisor). Check it
# explicitly so an existing docker without buildx doesn't short-circuit below.
if docker buildx version &>/dev/null 2>&1; then
  BUILDX_VER=$(docker buildx version)
  info "Docker buildx plugin already installed: ${BUILDX_VER}"
  BUILDX_OK=true
fi

if $DOCKER_OK && $COMPOSE_OK && $BUILDX_OK; then
  info "Docker, Compose and buildx plugins are already installed. Nothing to do."
  exit 0
fi

# ── install from Ubuntu's default repositories (universe) ─────────────────────
# No external apt repo or key — these all live in the stock Ubuntu archive.
PKGS=()
$DOCKER_OK  || PKGS+=(docker.io)
$COMPOSE_OK || PKGS+=(docker-compose-v2)
$BUILDX_OK  || PKGS+=(docker-buildx)

info "Installing from Ubuntu repositories: ${PKGS[*]}"
apt-get update -qq
apt-get install -y -qq "${PKGS[@]}"

if ! $DOCKER_OK; then
  systemctl enable --now docker
  info "Docker Engine installed and started."
fi
$COMPOSE_OK || info "Docker Compose plugin installed."
$BUILDX_OK  || info "Docker buildx plugin installed."

# ── verify ────────────────────────────────────────────────────────────────────
echo
info "Verifying installations..."

if ! docker --version; then
  error "Docker verification failed."
fi

if ! docker compose version; then
  error "Docker Compose plugin verification failed."
fi

if ! docker buildx version; then
  error "Docker buildx plugin verification failed."
fi

echo
info "All done. Docker, Compose and buildx plugins are ready."
