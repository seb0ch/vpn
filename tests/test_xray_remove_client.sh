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
  ]
}
EOF
  chmod 600 "${CONFIG}"
}

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Removing an existing client keeps the other and yields valid JSON.
make_fixture
XR_CLIENT=alice XR_CONFIG="${CONFIG}" python3 "${REPO_DIR}/xray/remove-client.py" \
  || fail "removal of existing client exited non-zero"
python3 - "$CONFIG" <<'PYEOF' || fail "post-removal JSON invalid or wrong"
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
emails = [c['email'] for c in cfg['inbounds'][0]['settings']['clients']]
assert emails == ['bob'], emails
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
