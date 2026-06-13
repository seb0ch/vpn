#!/usr/bin/env bash
# Smoke tests for xray/remove-client.py — no Docker required.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

CONFIG="${TMP}/config.json"
make_fixture() {
  cat > "${CONFIG}" <<'EOF'
{
  "inbounds": [
    {
      "port": 443,
      "settings": {
        "clients": [
          {"id": "uuid-alice", "flow": "xtls-rprx-vision", "email": "alice"},
          {"id": "uuid-bob", "flow": "xtls-rprx-vision", "email": "bob"}
        ]
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
      {"type": "field", "user": ["alice"], "outboundTag": "server2"},
      {"type": "field", "user": ["alice", "bob"], "outboundTag": "server3"}
    ]
  }
}
EOF
  chmod 600 "${CONFIG}"
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Removing an existing client keeps the other, strips its routing rules,
#    and yields valid JSON.
make_fixture
XR_CLIENT=alice XR_CONFIG="${CONFIG}" python3 "${REPO_DIR}/xray/remove-client.py" \
  || fail "removal of existing client exited non-zero"
python3 - "$CONFIG" <<'PYEOF' || fail "post-removal JSON invalid or wrong"
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
emails = [c['email'] for c in cfg['inbounds'][0]['settings']['clients']]
assert emails == ['bob'], emails
rules = cfg['routing']['rules']
# The alice-only rule (server2) must be DROPPED entirely (not just emptied);
# the geoip:private block stays; the shared rule (server3) keeps bob only.
assert {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': 'blocked'} in rules, rules
assert not any(r.get('outboundTag') == 'server2' for r in rules), rules
assert any(r.get('user') == ['bob'] and r['outboundTag'] == 'server3' for r in rules), rules
assert not any('alice' in (r.get('user') or []) for r in rules), rules
# No rule may be left with an empty user list (a dedicated rule must be dropped).
assert all(r.get('user') is None or len(r['user']) > 0 for r in rules), rules
PYEOF

# 2. File mode is preserved by the atomic replace.
mode="$(stat -f '%Lp' "${CONFIG}" 2>/dev/null || stat -c '%a' "${CONFIG}")"
[[ "${mode}" == "600" ]] || fail "mode not preserved: ${mode}"

# 3. Unknown client: exit 3, file untouched.
make_fixture
before="$(cat "${CONFIG}")"
set +e
XR_CLIENT=carol XR_CONFIG="${CONFIG}" python3 "${REPO_DIR}/xray/remove-client.py"
rc=$?
set -e
[[ "${rc}" -eq 3 ]] || fail "expected exit 3 for unknown client, got ${rc}"
[[ "$(cat "${CONFIG}")" == "${before}" ]] || fail "file modified for unknown client"

echo "OK: test_xray_remove_client"
