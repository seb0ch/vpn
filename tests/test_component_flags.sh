#!/usr/bin/env bash
# Tests for the component-selection helpers in lib/common.sh
# (parse_bool / render_compose / component_enabled) — no network, no Docker.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_DIR}/lib/common.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
eq()   { [[ "$1" == "$2" ]] || fail "$3 (got '$1', want '$2')"; }

# ── parse_bool ───────────────────────────────────────────────────────────────
eq "$(parse_bool ""      1)" "1" "empty falls back to the default"
eq "$(parse_bool ""      0)" "0" "empty falls back to the default"
eq "$(parse_bool "1"     0)" "1" "'1' is true"
eq "$(parse_bool "0"     1)" "0" "'0' is false"
eq "$(parse_bool "true"  0)" "1" "'true' is true"
eq "$(parse_bool "FALSE" 1)" "0" "'FALSE' is false (case-insensitive)"
eq "$(parse_bool "Yes"   0)" "1" "'Yes' is true (case-insensitive)"
eq "$(parse_bool "off"   1)" "0" "'off' is false"

parse_bool "maybe" 1 >/dev/null && fail "unrecognised value accepted"
parse_bool "2"     1 >/dev/null && fail "'2' accepted"

# ── render_compose ───────────────────────────────────────────────────────────
TMPL="${REPO_DIR}/docker-compose.yml.tmpl"
[[ -f "${TMPL}" ]] || fail "compose template missing"

# Both components kept: every service present, markers stripped.
both="$(render_compose "${TMPL}" "")"
grep -q '^  amneziawg:$' <<<"${both}" || fail "amneziawg dropped when enabled"
grep -q '^  xray:$'      <<<"${both}" || fail "xray dropped when enabled"
grep -q '^  dns:$'       <<<"${both}" || fail "dns dropped"
grep -q 'service:'       <<<"${both}" && fail "markers left in the rendered file"

# AmneziaWG off: dns goes with it (only AWG clients are DNAT'ed to it), and so
# does the xray service's depends_on fragment — otherwise compose would fail on
# a dependency that no longer exists.
no_awg="$(render_compose "${TMPL}" "amneziawg,dns")"
grep -qi 'amneziawg'  <<<"${no_awg}" && fail "amneziawg block survived"
grep -q '^  dns:$'    <<<"${no_awg}" && fail "dns block survived"
grep -q 'depends_on'  <<<"${no_awg}" && fail "depends_on kept without dns"
grep -q '^  xray:$'   <<<"${no_awg}" || fail "xray dropped with amneziawg"
grep -q 'image: xray' <<<"${no_awg}" || fail "xray body dropped with amneziawg"

# Xray off: mirror image — amneziawg and dns stay.
no_xray="$(render_compose "${TMPL}" "xray")"
grep -q 'xray'            <<<"${no_xray}" && fail "xray block survived"
grep -q '^  amneziawg:$'  <<<"${no_xray}" || fail "amneziawg dropped with xray"
grep -q '^  dns:$'        <<<"${no_xray}" || fail "dns dropped with xray"
grep -q 'depends_on'      <<<"${no_xray}" || fail "amneziawg lost its dns dependency"

# Every rendering keeps the file shorter than the template (markers removed).
[[ "$(wc -l <<<"${both}")" -lt "$(wc -l < "${TMPL}")" ]] || fail "markers not stripped"

render_compose "${REPO_DIR}/no-such-template.yml" "" >/dev/null 2>&1 \
  && fail "missing template accepted"

# ── component_enabled ────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

printf '%s\n' "${no_awg}" > "${TMPDIR_TEST}/docker-compose.yml"
component_enabled xray      "${TMPDIR_TEST}/docker-compose.yml" || fail "xray not detected"
component_enabled amneziawg "${TMPDIR_TEST}/docker-compose.yml" && fail "amneziawg falsely detected"
component_enabled dns       "${TMPDIR_TEST}/docker-compose.yml" && fail "dns falsely detected"

printf '%s\n' "${no_xray}" > "${TMPDIR_TEST}/awg-only.yml"
component_enabled amneziawg "${TMPDIR_TEST}/awg-only.yml" || fail "amneziawg not detected"
component_enabled dns       "${TMPDIR_TEST}/awg-only.yml" || fail "dns not detected"
component_enabled xray      "${TMPDIR_TEST}/awg-only.yml" && fail "xray falsely detected"

component_enabled xray "${TMPDIR_TEST}/missing.yml" && fail "missing compose file accepted"
component_enabled ""   "${TMPDIR_TEST}/docker-compose.yml" && fail "empty service name accepted"

# A commented-out or nested mention must not count as a deployed service.
printf 'services:\n  dns:\n    image: dns:1\n    # xray: not a service\n' \
  > "${TMPDIR_TEST}/commented.yml"
component_enabled xray "${TMPDIR_TEST}/commented.yml" && fail "comment counted as a service"

echo "OK: test_component_flags"
