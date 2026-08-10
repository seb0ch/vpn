#!/usr/bin/env bash
# lib/common.sh — utilities shared by all management scripts.
# Source this file; do not execute it directly.

# ── Logging ──────────────────────────────────────────────────────────────────

log_info()  { printf '[INFO]  %s\n'    "$*"; }
log_warn()  { printf '[WARN]  %s\n'    "$*" >&2; }
log_error() { printf '[ERROR] %s\n'    "$*" >&2; }

# ── Validation ───────────────────────────────────────────────────────────────

# Ensure the client name is non-empty and contains only safe characters.
# Allows letters, digits, hyphens, and underscores.
validate_client_name() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    log_error "Client name must not be empty."
    return 1
  fi
  if [[ ${#name} -gt 64 ]]; then
    log_error "Client name too long (max 64 characters)."
    return 1
  fi
  if [[ ! "${name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid client name '${name}'. Use only letters, digits, hyphens (-), and underscores (_)."
    return 1
  fi
}

# ── Component selection ───────────────────────────────────────────────────────
# The stack ships two client-facing components, AmneziaWG and Xray, and either
# can be switched off for a single-protocol host (ENABLE_AMNEZIAWG / ENABLE_XRAY
# at deploy time). The dns service follows AmneziaWG: only AWG clients are
# DNAT'ed to it, while Xray resolves through the public resolvers in its own
# config.json — so an Xray-only host doesn't deploy it.

# parse_bool <value> <default> — print "1" or "0" for a boolean env value.
# An empty value yields <default>. Returns 1 without printing on an
# unrecognised value, so the caller can name the offending variable.
# Lower-casing goes through `tr` rather than `${var,,}` to stay usable under the
# bash 3.2 that ships with macOS (where the tests may run).
parse_bool() {
  local val def
  val="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  def="${2:-1}"
  if [[ -z "${val}" ]]; then
    printf '%s' "${def}"
    return 0
  fi
  case "${val}" in
    1|true|yes|y|on)  printf '1' ;;
    0|false|no|n|off) printf '0' ;;
    *) return 1 ;;
  esac
}

# component_enabled <service> <compose_file> — return 0 iff <service> is part of
# the deployment. The generated docker-compose.yml is the source of truth for
# what actually runs, so client-management scripts don't need to be told which
# deploy-time flags were used.
component_enabled() {
  local svc="${1:-}" file="${2:-docker-compose.yml}"
  [[ -n "${svc}" && -f "${file}" ]] || return 1
  grep -qE "^  ${svc}:[[:space:]]*$" "${file}"
}

# render_compose <template> [disabled] — print <template> with every block whose
# marker names a service in the comma-separated <disabled> list removed, and all
# markers stripped from the output.
#
# A marker is `# >>> <kind>: <name>` … `# <<< <kind>: <name>` at any indent. The
# kind is documentation only (`service:` for a whole service, `needs:` for a
# fragment such as one service's depends_on on another); the block is dropped
# when <name> is disabled. Blocks do not nest.
render_compose() {
  local tmpl="${1:-}" disabled="${2:-}"
  [[ -f "${tmpl}" ]] || { log_error "Compose template not found: ${tmpl}"; return 1; }
  awk -v disabled="${disabled}" '
    BEGIN { n = split(disabled, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") drop[a[i]] = 1 }
    /^[[:space:]]*# >>> [a-z]+: / { if ($NF in drop) skip = 1; next }
    /^[[:space:]]*# <<< [a-z]+: / { if ($NF in drop) skip = 0; next }
    # Collapse the blank-line runs a removed block leaves behind, so the
    # generated file reads like a hand-written one.
    !skip {
      if ($0 ~ /^[[:space:]]*$/) { if (blank) next; blank = 1 } else blank = 0
      print
    }
  ' "${tmpl}"
}

# ── Network ───────────────────────────────────────────────────────────────────

# Return 0 iff the single argument is a well-formed dotted-quad IPv4 address.
validate_ipv4() {
  local ip="${1:-}" octet="(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
  [[ "${ip}" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
}

# Fetch the server's public IPv4 address via api.ipify.org.
get_public_ip() {
  local ip
  if ! ip=$(curl -sf --max-time 10 https://api.ipify.org); then
    log_error "Could not determine public IP address (curl failed)."
    return 1
  fi
  if ! validate_ipv4 "${ip}"; then
    log_error "Public IP response is not a valid IPv4 address: '${ip}'"
    return 1
  fi
  printf '%s' "${ip}"
}
