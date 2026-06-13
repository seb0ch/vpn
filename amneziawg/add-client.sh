#!/usr/bin/env bash
set -euo pipefail
umask 077   # client config holds the client private key + PSK

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <client_name>" >&2
  exit 1
fi

readonly CLIENT_NAME="$1"
validate_client_name "${CLIENT_NAME}"

readonly CONF="conf/awg0.conf"
readonly CLIENT_CONF="../clients/${CLIENT_NAME}_amneziawg.conf"

if [[ -f "${CLIENT_CONF}" ]]; then
  log_error "Client '${CLIENT_NAME}' already exists (${CLIENT_CONF} found)."
  exit 1
fi

# ── Read server parameters from awg0.conf ─────────────────────────────────────
SERVER_PUBLIC_KEY=$(cat conf/server_public.key)
LISTEN_PORT=$(awk '/^ListenPort/{print $3}' "${CONF}")
JC=$(awk   '/^Jc  *=/{print $3}' "${CONF}")
JMIN=$(awk '/^Jmin/{print $3}'   "${CONF}")
JMAX=$(awk '/^Jmax/{print $3}'   "${CONF}")
S1=$(awk   '/^S1  *=/{print $3}' "${CONF}")
S2=$(awk   '/^S2  *=/{print $3}' "${CONF}")
S3=$(awk   '/^S3  *=/{print $3}' "${CONF}")
S4=$(awk   '/^S4  *=/{print $3}' "${CONF}")
H1=$(awk   '/^H1  *=/{print $3}' "${CONF}")
H2=$(awk   '/^H2  *=/{print $3}' "${CONF}")
H3=$(awk   '/^H3  *=/{print $3}' "${CONF}")
H4=$(awk   '/^H4  *=/{print $3}' "${CONF}")

# ── Generate client keypair + PSK inside the running container ────────────────
KEY_OUTPUT=$(docker exec amneziawg sh -c '
  PRIV=$(awg genkey)
  PUB=$(echo "$PRIV" | awg pubkey)
  PSK=$(awg genpsk)
  printf "%s\n%s\n%s\n" "$PRIV" "$PUB" "$PSK"
')
CLIENT_PRIVATE_KEY=$(sed -n '1p' <<< "${KEY_OUTPUT}")
CLIENT_PUBLIC_KEY=$(sed  -n '2p' <<< "${KEY_OUTPUT}")
CLIENT_PSK=$(sed         -n '3p' <<< "${KEY_OUTPUT}")

[[ -n "${CLIENT_PRIVATE_KEY}" ]] || { log_error "Failed to generate client private key."; exit 1; }
[[ -n "${CLIENT_PUBLIC_KEY}"  ]] || { log_error "Failed to derive client public key.";  exit 1; }
[[ -n "${CLIENT_PSK}"         ]] || { log_error "Failed to generate pre-shared key.";   exit 1; }

SERVER_IP=$(get_public_ip)

# ── Allocate the next client IP and append peer (locked to prevent races) ────
# flock ensures concurrent add-client calls cannot allocate the same IP.
(
  flock -x 200 || { log_error "Could not acquire lock on ${CONF}"; exit 1; }

  # Only match IPs in AllowedIPs lines (peer sections), not in PostUp/PostDown rules.
  LAST_IP=$(grep '^AllowedIPs' "${CONF}" | grep -Eo '10\.8\.0\.[0-9]{1,3}' | tail -n 1 || true)
  if [[ -z "${LAST_IP}" ]]; then
    NEXT_IP="10.8.0.2"
  else
    LAST_OCTET="${LAST_IP##*.}"
    if (( LAST_OCTET >= 254 )); then
      log_error "IP address space exhausted (10.8.0.2–10.8.0.254 are all in use)."
      exit 1
    fi
    NEXT_IP="10.8.0.$(( LAST_OCTET + 1 ))"
  fi

  # ── Append peer to the server config (persists across restarts) ─────────────
  cat >> "${CONF}" <<PEER_EOF

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${NEXT_IP}/32
PEER_EOF

  # Export NEXT_IP for the parent shell via a temp file.
  printf '%s' "${NEXT_IP}" > "conf/.next_ip_${CLIENT_NAME}"

) 200>"${CONF}.lock"

NEXT_IP=$(cat "conf/.next_ip_${CLIENT_NAME}")
rm -f "conf/.next_ip_${CLIENT_NAME}"

# ── Write client config file ──────────────────────────────────────────────────
cat > "${CLIENT_CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${NEXT_IP}/32
DNS = 10.8.0.1
MTU = 1368

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_IP}:${LISTEN_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "${CLIENT_CONF}"

# ── Hot-reload: sync the new peer without restarting ─────────────────────────
# Strip awg-quick directives (Address, PostUp, PostDown, etc.) for awg syncconf.
docker exec amneziawg sh -c '
  grep -v -E "^(Address|PostUp|PostDown|SaveConfig|MTU|DNS|Table|PreUp|PreDown)\s*=" /etc/awg/awg0.conf > /tmp/awg0_stripped.conf
  awg syncconf awg0 /tmp/awg0_stripped.conf
  rm -f /tmp/awg0_stripped.conf
'

# ── Print QR code to terminal ─────────────────────────────────────────────────
echo ""
echo "QR code:"
docker exec -i amneziawg qrencode \
  -t ansiutf8 < "${CLIENT_CONF}" 2>/dev/null \
  || echo "(qrencode not available in the amneziawg image)"

log_info "Client '${CLIENT_NAME}' added — IP ${NEXT_IP}"
