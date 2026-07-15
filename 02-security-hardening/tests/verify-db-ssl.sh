#!/usr/bin/env bash
set -euo pipefail
if [ -n "${1:-}" ] && [ -f "$1" ]; then source "$1"; fi

PORT="${PRIMARY_PORT:-5444}"
USER="${SYSTEM_USER:-enterprisedb}"

if [ -z "${PGPASSWORD:-}" ] && [ ! -f "${HOME}/.pgpass" ]; then
    echo "[WARNING] No PGPASSWORD or ~/.pgpass found. psql may fail with scram-sha-256."
fi

echo "=== [POST-FLIGHT] Checking Cluster Runtime SSL Status ==="
SSL_STATUS=$(psql -p "$PORT" -U "$USER" -d postgres -t -A -c "SHOW ssl;" 2>/dev/null || echo "connection_failed")

if [ "$SSL_STATUS" == "connection_failed" ]; then
    echo "[POST-FLIGHT FAIL] Could not connect to database. Check authentication."
    exit 1
fi
if [ "$SSL_STATUS" != "on" ]; then
    echo "[POST-FLIGHT FAIL] SSL layer is inactive on running engine!"
    exit 1
fi
echo "[POST-FLIGHT SUCCESS] Core database has actively bound SSL network layers."
