#!/usr/bin/env bash
# Smoke tests for amneziawg/remove-peer.py — no Docker required.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

CONF="${TMP}/awg0.conf"
make_fixture() {
  cat > "${CONF}" <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24
ListenPort = 51820

[Peer]
# alice
PublicKey = ALICEPUB
PresharedKey = ALICEPSK
AllowedIPs = 10.8.0.2/32

[Peer]
# bob
PublicKey = BOBPUB
PresharedKey = BOBPSK
AllowedIPs = 10.8.0.3/32

[Peer]
# my-client_2
PublicKey = DASHPUB
PresharedKey = DASHPSK
AllowedIPs = 10.8.0.4/32
EOF
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Removing an existing peer deletes exactly that block.
make_fixture
AWG_CLIENT=alice AWG_CONF="${CONF}" python3 "${REPO_DIR}/amneziawg/remove-peer.py" \
  || fail "removal of existing peer exited non-zero"
grep -q 'ALICEPUB' "${CONF}" && fail "alice peer still present"
grep -q 'BOBPUB' "${CONF}" || fail "bob peer was damaged"
grep -q 'PrivateKey = SERVERKEY' "${CONF}" || fail "[Interface] was damaged"

# 2. A name with hyphen and underscore (allowed by validate_client_name) works.
AWG_CLIENT=my-client_2 AWG_CONF="${CONF}" python3 "${REPO_DIR}/amneziawg/remove-peer.py" \
  || fail "removal of hyphen/underscore name exited non-zero"
grep -q 'DASHPUB' "${CONF}" && fail "my-client_2 peer still present"

# 3. Removing the LAST peer leaves exactly the expected file content.
AWG_CLIENT=bob AWG_CONF="${CONF}" python3 "${REPO_DIR}/amneziawg/remove-peer.py" \
  || fail "removal of last peer exited non-zero"
expected="$(cat <<'EOF'
[Interface]
PrivateKey = SERVERKEY
Address = 10.8.0.1/24
ListenPort = 51820
EOF
)"
[[ "$(cat "${CONF}")" == "${expected}" ]] || fail "unexpected content after removing all peers: $(cat "${CONF}")"

# 4. Unknown peer: exit 3, file untouched.
make_fixture
before="$(cat "${CONF}")"
set +e
AWG_CLIENT=carol AWG_CONF="${CONF}" python3 "${REPO_DIR}/amneziawg/remove-peer.py"
rc=$?
set -e
[[ "${rc}" -eq 3 ]] || fail "expected exit 3 for unknown peer, got ${rc}"
[[ "$(cat "${CONF}")" == "${before}" ]] || fail "file modified for unknown peer"

# 5. A name that is a prefix of another client must not match it.
make_fixture
set +e
AWG_CLIENT=ali AWG_CONF="${CONF}" python3 "${REPO_DIR}/amneziawg/remove-peer.py"
rc=$?
set -e
[[ "${rc}" -eq 3 ]] || fail "prefix name 'ali' must not match 'alice'"

echo "OK: test_remove_peer"
