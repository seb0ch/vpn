#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG="/etc/xray/config.json"

echo "=== Starting Xray ==="
xray version

exec xray run -c "${CONFIG}"
