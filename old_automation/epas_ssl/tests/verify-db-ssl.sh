#!/bin/bash
# ==============================================================================
# EPAS SSL POST-FLIGHT CHECK - RUNTIME DATABASE ENCRYPTION VALIDATION
# ==============================================================================
set -e

# Load variables from the active environment file if provided
if [ -n "$1" ] && [ -f "$1" ]; then
    source "$1"
fi

# Fallback defaults if env values aren't set in shell
PORT="${PRIMARY_PORT:-5444}"
USER="${SYSTEM_USER:-enterprisedb}"

echo "=== [POST-FLIGHT] Checking Cluster Runtime SSL Status ==="

# 1. Check if SSL is globally ON
SSL_STATUS=$(psql -p "$PORT" -U "$USER" -d postgres -t -A -c "SHOW ssl;")
echo "Database Configured SSL Layer: $SSL_STATUS"

if [ "$SSL_STATUS" != "on" ]; then
    echo "[FAIL] SSL is not active on port $PORT!"
    exit 1
fi

# 2. Print out current replication stream security details
echo -e "\n=== Active Encrypted Streaming Replication Connections ==="
psql -p "$PORT" -U "$USER" -d postgres -c "
SELECT client_addr, ssl, ssl_version, ssl_cipher 
FROM pg_stat_ssl 
JOIN pg_stat_replication ON pg_stat_ssl.pid = pg_stat_replication.pid;"

echo "[SUCCESS] Post-flight runtime check complete."