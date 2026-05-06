#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ $# -ne 2 ]]; then
  cat >&2 <<USAGE
Usage: $0 <tag> <vless_url>

  <tag>       Outbound tag (used by set-route.sh to route a user via this upstream).
  <vless_url> VLESS REALITY link from the upstream server's add-client.sh output.

Example:
  $0 server2 'vless://<uuid>@1.2.3.4:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=cloudflare.com&fp=chrome&pbk=<pbk>&sid=<sid>&type=tcp#server1-uplink'
USAGE
  exit 1
fi

readonly TAG="$1"
readonly VLESS_URL="$2"
readonly CONFIG="conf/config.json"

validate_client_name "${TAG}"

if [[ ! -f "${CONFIG}" ]]; then
  log_error "${CONFIG} not found. Run deploy.sh first."
  exit 1
fi

(
  flock -x 200 || { log_error "Could not acquire lock on ${CONFIG}"; exit 1; }

  XR_TAG="${TAG}" XR_URL="${VLESS_URL}" XR_CONFIG="${CONFIG}" \
  python3 - <<'PYEOF'
import json, os, sys, tempfile
from urllib.parse import urlparse, parse_qs

config_path = os.environ['XR_CONFIG']
tag         = os.environ['XR_TAG']
url         = os.environ['XR_URL']

if not url.startswith('vless://'):
    print("Error: argument is not a vless:// URL", file=sys.stderr)
    sys.exit(1)

parsed = urlparse(url)
uuid = parsed.username or ''
host = parsed.hostname or ''
port = parsed.port or 443
qs   = parse_qs(parsed.query)

def q(key, default):
    # Treat both missing keys and empty values as "use default" — a vless URL
    # like "...&flow=&..." should not produce an empty `flow` field.
    v = qs.get(key, [''])[0]
    return v if v else default

pbk  = q('pbk', '')
sid  = q('sid', '')
sni  = q('sni', 'cloudflare.com')
flow = q('flow', 'xtls-rprx-vision')
fp   = q('fp', 'chrome')
sec  = q('security', 'reality')

for name, val in (('uuid', uuid), ('host', host), ('pbk', pbk)):
    if not val:
        print(f"Error: missing '{name}' in vless URL", file=sys.stderr)
        sys.exit(1)
if sec != 'reality':
    print(f"Error: only REALITY security is supported (got '{sec}')", file=sys.stderr)
    sys.exit(1)

with open(config_path) as f:
    config = json.load(f)

outbounds = config.setdefault('outbounds', [])
if tag in ('direct', 'blocked'):
    print(f"Error: tag '{tag}' is reserved for the built-in outbounds", file=sys.stderr)
    sys.exit(1)
if any(o.get('tag') == tag for o in outbounds):
    print(f"Error: outbound with tag '{tag}' already exists", file=sys.stderr)
    sys.exit(1)

new_ob = {
    "tag": tag,
    "protocol": "vless",
    "settings": {
        "vnext": [{
            "address": host,
            "port": port,
            "users": [{
                "id": uuid,
                "encryption": "none",
                "flow": flow,
            }]
        }]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "serverName": sni,
            "publicKey": pbk,
            "shortId": sid,
            "fingerprint": fp,
        }
    }
}

outbounds.append(new_ob)

# Enforce a stable order: freedom outbounds first (default fallthrough for
# unrouted traffic), user-defined outbounds in the middle (relative order
# preserved by Python's stable sort), blackhole outbounds last. Holds even
# if the config was previously hand-edited into an unusual layout.
def _order_key(o):
    p = o.get('protocol')
    if p == 'freedom':   return 0
    if p == 'blackhole': return 2
    return 1
outbounds.sort(key=_order_key)

# Atomic write: write to a sibling temp file, fsync, then rename. A SIGINT,
# OOM, or disk-full mid-write leaves config.json untouched instead of empty.
# mkstemp() defaults to mode 0600; mirror the existing file's mode so we
# don't silently downgrade permissions of the live config.
cfg_dir = os.path.dirname(os.path.abspath(config_path)) or '.'
fd, tmp = tempfile.mkstemp(dir=cfg_dir, prefix='.config.', suffix='.json.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(config, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chmod(tmp, os.stat(config_path).st_mode & 0o777)
    except FileNotFoundError:
        pass
    os.replace(tmp, config_path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise

print(f"Added upstream '{tag}' -> {host}:{port}", file=sys.stderr)
PYEOF

  # Restart inside the lock so a concurrent add-client.sh can't slip a write
  # in between our os.replace and our restart.
  docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" restart xray >/dev/null \
    || { log_error "Failed to restart xray container"; exit 1; }
) 200>"${CONFIG}.lock"

log_info "Upstream '${TAG}' added. Route a user via: ./xray/set-route.sh <user> ${TAG}"
