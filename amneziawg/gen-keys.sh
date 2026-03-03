#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

rand32() { od -An -N4 -tu4 /dev/urandom | tr -d ' '; }

# ── Bootstrap config from template if missing ─────────────────────────────────
if [[ ! -f conf/awg0.conf ]]; then
  [[ -f conf/awg0.tmpl ]] || { log_error "conf/awg0.tmpl not found"; exit 1; }
  cp conf/awg0.tmpl conf/awg0.conf
  log_info "Created conf/awg0.conf from template"
fi

# ── Obfuscation parameters ────────────────────────────────────────────────────
# H1-H4 ranges are split across the full 32-bit space in four equal segments.
# Cap each H*_MAX to 2147483647 (max signed 32-bit int) to prevent overflow.
readonly SEGMENT=$(( 2147483642 / 4 ))
readonly H_LIMIT=2147483647
H1_MIN=$(( 5 + $(rand32) % SEGMENT ))
H1_MAX=$(( H1_MIN + $(rand32) % 1000000 + 1 ))
H2_MIN=$(( 5 + SEGMENT + $(rand32) % SEGMENT ))
H2_MAX=$(( H2_MIN + $(rand32) % 1000000 + 1 ))
H3_MIN=$(( 5 + SEGMENT * 2 + $(rand32) % SEGMENT ))
H3_MAX=$(( H3_MIN + $(rand32) % 1000000 + 1 ))
H4_MIN=$(( 5 + SEGMENT * 3 + $(rand32) % SEGMENT ))
H4_MAX=$(( H4_MIN + $(rand32) % 1000000 + 1 ))
# Clamp to valid 32-bit range.
(( H1_MAX > H_LIMIT )) && H1_MAX=${H_LIMIT}
(( H2_MAX > H_LIMIT )) && H2_MAX=${H_LIMIT}
(( H3_MAX > H_LIMIT )) && H3_MAX=${H_LIMIT}
(( H4_MAX > H_LIMIT )) && H4_MAX=${H_LIMIT}

readonly S_MIN=0
readonly S_MAX=32
readonly S4_MAX=16

JC=$(( $(rand32) % 10 + 1 ))
JMIN=$(( $(rand32) % 32 + 1 ))
JMAX=$(( $(rand32) % (64 - JMIN + 1) + JMIN ))
S1=$(( $(rand32) % 32 + 1 ))
S2=$(( $(rand32) % 32 + 1 ))
S3=$(( $(rand32) % 32 + 1 ))
S4=$(( $(rand32) % 16 + 1 ))

AMNEZIAWG_PORT=${AMNEZIAWG_PORT:-$(shuf -i 49152-65535 -n 1)}

# ── Generate server keypair inside the container ──────────────────────────────
KEY_OUTPUT=$(docker run --rm --entrypoint sh amneziawg -c '
  SRV_PRIV=$(awg genkey)
  SRV_PUB=$(echo "$SRV_PRIV" | awg pubkey)
  printf "%s\n%s\n" "$SRV_PRIV" "$SRV_PUB"
')
SERVER_PRIVATE_KEY=$(sed -n '1p' <<< "${KEY_OUTPUT}")
SERVER_PUBLIC_KEY=$(sed  -n '2p' <<< "${KEY_OUTPUT}")

[[ -n "${SERVER_PRIVATE_KEY}" ]] || { log_error "Failed to generate server private key."; exit 1; }
[[ -n "${SERVER_PUBLIC_KEY}"  ]] || { log_error "Failed to derive server public key.";   exit 1; }

# ── Persist keys with restricted permissions ──────────────────────────────────
printf '%s\n' "${SERVER_PRIVATE_KEY}" > conf/server_private.key
printf '%s\n' "${SERVER_PUBLIC_KEY}"  > conf/server_public.key
chmod 600 conf/server_private.key conf/server_public.key

# ── Patch the Interface section of awg0.conf ─────────────────────────────────
sed -i \
  -e "s|^PrivateKey = .*|PrivateKey = ${SERVER_PRIVATE_KEY}|" \
  -e "s|^ListenPort = .*|ListenPort = ${AMNEZIAWG_PORT}|" \
  -e "s|^Jc = .*|Jc = ${JC}|" \
  -e "s|^Jmin = .*|Jmin = ${JMIN}|" \
  -e "s|^Jmax = .*|Jmax = ${JMAX}|" \
  -e "s|^S1 = .*|S1 = ${S1}|" \
  -e "s|^S2 = .*|S2 = ${S2}|" \
  -e "s|^S3 = .*|S3 = ${S3}|" \
  -e "s|^S4 = .*|S4 = ${S4}|" \
  -e "s|^H1 = .*|H1 = ${H1_MIN}-${H1_MAX}|" \
  -e "s|^H2 = .*|H2 = ${H2_MIN}-${H2_MAX}|" \
  -e "s|^H3 = .*|H3 = ${H3_MIN}-${H3_MAX}|" \
  -e "s|^H4 = .*|H4 = ${H4_MIN}-${H4_MAX}|" \
  conf/awg0.conf

log_info "AmneziaWG server config generated (port ${AMNEZIAWG_PORT})"
