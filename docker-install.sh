#!/usr/bin/env bash
set -euo pipefail

# Docker + Docker Compose plugin installer for Ubuntu 24.04+
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

if $DOCKER_OK && $COMPOSE_OK; then
  info "Both Docker and Docker Compose plugin are already installed. Nothing to do."
  exit 0
fi

# ── install Docker (via official apt repo) ────────────────────────────────────
if ! $DOCKER_OK; then
  info "Installing Docker Engine..."

  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin

  systemctl enable --now docker
  info "Docker Engine installed and started."
fi

# ── install Docker Compose plugin ─────────────────────────────────────────────
if ! $COMPOSE_OK; then
  info "Installing Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin
  info "Docker Compose plugin installed."
fi

# ── verify ────────────────────────────────────────────────────────────────────
echo
info "Verifying installations..."

if ! docker --version; then
  error "Docker verification failed."
fi

if ! docker compose version; then
  error "Docker Compose plugin verification failed."
fi

echo
info "All done. Docker and Docker Compose plugin are ready."
