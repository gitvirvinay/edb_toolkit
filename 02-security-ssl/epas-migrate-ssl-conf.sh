#!/usr/bin/env bash
set -euo pipefail

# --- DEFAULT FALLBACK VALUES ---
DEFAULT_OLD_DATA="/pgdata/as15/data"
DEFAULT_NEW_DATA="/pgdata/as17/data"
DEFAULT_USER="enterprisedb"

# --- INTERACTIVE PROMPTS ---
echo "===================================================================="
echo "      EPAS 15 -> EPAS 17 SSL Configuration Extraction Utility"
echo "===================================================================="

read -p "Enter EPAS 15 Data Directory [${DEFAULT_OLD_DATA}]: " INPUT_OLD_DATA
OLD_DATA="${INPUT_OLD_DATA:-$DEFAULT_OLD_DATA}"

read -p "Enter EPAS 17 Data Directory [${DEFAULT_NEW_DATA}]: " INPUT_NEW_DATA
NEW_DATA="${INPUT_NEW_DATA:-$DEFAULT_NEW_DATA}"

read -p "Enter Postgres System User [${DEFAULT_USER}]: " INPUT_USER
EXPECTED_USER="${INPUT_USER:-$DEFAULT_USER}"

echo "--------------------------------------------------------------------"

OLD_CONF="${OLD_DATA}/postgresql.conf"
OUTPUT_CONF="${NEW_DATA}/conf.d/ssl.conf"

# --- VERIFICATIONS ---
if [ ! -f "$OLD_CONF" ]; then
    echo "[ERROR] EPAS 15 configuration file not found at: ${OLD_CONF}" >&2
    exit 1
fi

# Ensure conf.d target directory exists in EPAS 17
mkdir -p "$(dirname "$OUTPUT_CONF")"

echo "[INFO] Extracting SSL directives from ${OLD_CONF}..."

# --- EXTRACT SSL DIRECTIVES ---
SSL_ENABLED=$(grep -i "^\s*ssl\s*=" "$OLD_CONF" | tail -n 1 || true)
SSL_CERT=$(grep -i "^\s*ssl_cert_file\s*=" "$OLD_CONF" | tail -n 1 || true)
SSL_KEY=$(grep -i "^\s*ssl_key_file\s*=" "$OLD_CONF" | tail -n 1 || true)
SSL_CA=$(grep -i "^\s*ssl_ca_file\s*=" "$OLD_CONF" | tail -n 1 || true)
SSL_CRL=$(grep -i "^\s*ssl_crl_file\s*=" "$OLD_CONF" | tail -n 1 || true)

if [ -z "$SSL_ENABLED" ] && [ -z "$SSL_CERT" ] && [ -z "$SSL_KEY" ]; then
    echo "[WARNING] No active SSL directives found in ${OLD_CONF}."
fi

# --- WRITE TO ssl.conf ---
echo "[INFO] Creating ${OUTPUT_CONF}..."

cat <<EOF > "$OUTPUT_CONF"
# ====================================================================
# Extracted EPAS 15 SSL Configuration
# Location: ${OUTPUT_CONF}
# ====================================================================

${SSL_ENABLED:-# ssl = off}
${SSL_CERT:-# ssl_cert_file = ''}
${SSL_KEY:-# ssl_key_file = ''}
${SSL_CA:-# ssl_ca_file = ''}
${SSL_CRL:-# ssl_crl_file = ''}
EOF

# Set strict permissions required by Postgres
chmod 600 "$OUTPUT_CONF"

if [ "$(id -u)" -eq 0 ]; then
    chown -R "${EXPECTED_USER}:${EXPECTED_USER}" "$(dirname "$OUTPUT_CONF")"
fi

echo "[SUCCESS] Generated ${OUTPUT_CONF} successfully!"