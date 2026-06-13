#!/usr/bin/env bash
# Tests for lib/common.sh:validate_ipv4 — no network required.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_DIR}/lib/common.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

validate_ipv4 "203.0.113.7"   || fail "valid IP rejected"
validate_ipv4 "1.2.3.4"       || fail "valid IP rejected"
validate_ipv4 "255.255.255.255" || fail "valid IP rejected"

validate_ipv4 "999.1.1.1"     && fail "octet >255 accepted"
validate_ipv4 "1.2.3"         && fail "3 octets accepted"
validate_ipv4 ""              && fail "empty accepted"
validate_ipv4 "1.2.3.4.5"     && fail "5 octets accepted"
validate_ipv4 "<html>evil"    && fail "html accepted"
validate_ipv4 "$(printf '1.2.3.4\nDNS = 6.6.6.6')" && fail "multiline accepted"

echo "OK: test_validate_ipv4"
