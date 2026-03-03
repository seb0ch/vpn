#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── 1. Verify Docker is installed ────────────────────────────────────────────
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

# ── 2. Build Docker images ───────────────────────────────────────────────────
log_info "Building Docker images…"
docker build -t amneziawg ./amneziawg
docker build -t xray      ./xray
docker build -t dns       ./dns

# ── 3. AmneziaWG keys ────────────────────────────────────────────────────────
if [[ ! -f amneziawg/conf/server_private.key ]]; then
  log_info "Generating AmneziaWG server keys…"
  ./amneziawg/gen-keys.sh
else
  log_info "AmneziaWG keys already exist — skipping."
  log_info "(Delete amneziawg/conf/server_private.key to regenerate.)"
fi

# ── 4. docker-compose.yml ────────────────────────────────────────────────────
AWG_PORT=$(grep "^ListenPort" amneziawg/conf/awg0.conf | awk '{print $3}')
if [[ -z "${AWG_PORT}" ]]; then
  log_error "Could not read ListenPort from amneziawg/conf/awg0.conf"
  exit 1
fi
sed "s/AWG_PORT/${AWG_PORT}/g" docker-compose.yml.tmpl > docker-compose.yml
log_info "Generated docker-compose.yml (AWG port ${AWG_PORT})"

# ── 5. Xray keys ─────────────────────────────────────────────────────────────
if [[ ! -f xray/conf/reality_keys.txt ]]; then
  log_info "Generating Xray REALITY keys…"
  ./xray/gen-keys.sh
else
  log_info "Xray keys already exist — skipping."
  log_info "(Delete xray/conf/reality_keys.txt to regenerate.)"
fi

# ── 6. Start services ────────────────────────────────────────────────────────
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
