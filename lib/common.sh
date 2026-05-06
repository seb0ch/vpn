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

# ── Network ───────────────────────────────────────────────────────────────────

# Fetch the server's public IPv4 address via api.ipify.org.
get_public_ip() {
  local ip
  if ! ip=$(curl -sf --max-time 10 https://api.ipify.org); then
    log_error "Could not determine public IP address (curl failed)."
    return 1
  fi
  if [[ -z "${ip}" ]]; then
    log_error "Public IP response was empty."
    return 1
  fi
  printf '%s' "${ip}"
}
