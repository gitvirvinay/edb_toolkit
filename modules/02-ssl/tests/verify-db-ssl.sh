#!/usr/bin/env bash
set -euo pipefail
# verify-db-ssl.sh — after epas-ssl-setup.sh: confirm the running EPAS reports ssl = on.
# Usage: $0 [--env conf/site.env]   (default: conf/site.env in the repo; works with defaults too)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../lib/common.sh"
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) sed -n '3,4p' "$0"; exit 0 ;; esac
load_env optional

PORT="${PRIMARY_PORT}"
USER="${SYSTEM_USER}"

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
