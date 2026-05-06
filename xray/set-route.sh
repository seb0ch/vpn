#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

if [[ $# -ne 2 ]]; then
  cat >&2 <<USAGE
Usage: $0 <user> <outbound_tag|direct>

  <user>         Existing client name (matches the 'email' field in config.json).
  <outbound_tag> Tag from add-upstream.sh — routes this user's traffic via that upstream.
                 Use 'direct' to remove any per-user rule; the user then falls through
                 to the default outbound (freedom -> local exit).

Examples:
  $0 user1 server2     # route user1 via the 'server2' upstream
  $0 user1 direct      # remove the rule, send user1 traffic out locally
USAGE
  exit 1
fi

readonly CLIENT="$1"
readonly TARGET="$2"
readonly CONFIG="conf/config.json"

validate_client_name "${CLIENT}"
if [[ "${TARGET}" != "direct" ]]; then
  validate_client_name "${TARGET}"
fi

if [[ ! -f "${CONFIG}" ]]; then
  log_error "${CONFIG} not found. Run deploy.sh first."
  exit 1
fi

(
  flock -x 200 || { log_error "Could not acquire lock on ${CONFIG}"; exit 1; }

  XR_CLIENT="${CLIENT}" XR_TARGET="${TARGET}" XR_CONFIG="${CONFIG}" \
  python3 - <<'PYEOF'
import json, os, sys, tempfile

config_path = os.environ['XR_CONFIG']
client      = os.environ['XR_CLIENT']
target      = os.environ['XR_TARGET']

with open(config_path) as f:
    config = json.load(f)

# Xray matches the routing `user` field against the email of any inbound
# client, so look across all inbounds — not just inbounds[0].
known_emails = set()
for inb in config.get('inbounds', []):
    for c in (inb.get('settings') or {}).get('clients', []) or []:
        email = c.get('email')
        if email:
            known_emails.add(email)
if client not in known_emails:
    print(f"Error: no client with email '{client}' in any inbound", file=sys.stderr)
    sys.exit(1)

routing = config.setdefault('routing', {'domainStrategy': 'IPIfNonMatch', 'rules': []})
rules = routing.setdefault('rules', [])

# Strip this client from every rule's `user` list. A rule that targeted only
# this client is dropped entirely; a rule that targeted a group is kept with
# the client removed. This makes set-route the single source of truth for
# this client's per-user routing without disturbing group rules.
new_rules = []
for r in rules:
    users = r.get('user') or []
    if client in users:
        remaining = [u for u in users if u != client]
        if remaining:
            r = {**r, 'user': remaining}
            new_rules.append(r)
        # else: the rule was dedicated to this client; drop it.
    else:
        new_rules.append(r)
rules[:] = new_rules

if target == 'direct':
    print(f"Removed routing rule for '{client}' (falls through to default outbound)",
          file=sys.stderr)
else:
    tags = {o.get('tag') for o in config.get('outbounds', [])}
    if target not in tags:
        avail = sorted(t for t in tags if t)
        print(f"Error: no outbound with tag '{target}'. Available: {avail}",
              file=sys.stderr)
        sys.exit(1)

    # Insert the new rule after any leading blocked rules but before the first
    # existing user rule, so per-user rules form one contiguous block and
    # global blocks (e.g. geoip:private -> blocked) keep precedence.
    insert_at = 0
    for i, r in enumerate(rules):
        if r.get('user'):
            break
        if r.get('outboundTag') == 'blocked':
            insert_at = i + 1
    rules.insert(insert_at, {
        "type": "field",
        "user": [client],
        "outboundTag": target,
    })
    print(f"User '{client}' routed via outbound '{target}'", file=sys.stderr)

# Atomic write: temp file in the same directory, fsync, rename. Avoids a
# truncated config.json if the process is killed mid-write. Mirror the
# existing file's mode so mkstemp's 0600 default doesn't downgrade it.
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
PYEOF

  # Restart inside the lock so a concurrent add-client.sh can't slip a write
  # in between our os.replace and our restart.
  docker compose -f "${SCRIPT_DIR}/../docker-compose.yml" restart xray >/dev/null \
    || { log_error "Failed to restart xray container"; exit 1; }
) 200>"${CONFIG}.lock"

log_info "Done."
