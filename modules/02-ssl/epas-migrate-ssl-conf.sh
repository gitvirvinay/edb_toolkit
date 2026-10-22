#!/usr/bin/env bash
set -euo pipefail

# epas-migrate-ssl-conf.sh — copy the SSL settings of an OLD EPAS cluster (postgresql.conf) into
# conf.d/ssl.conf of the NEW cluster (major upgrade). Defaults come from conf/site.env:
# new data dir = DATA_TOP, user = SYSTEM_USER, old data dir = /u001/data/as<OLD_EPAS_VERSION>.
# Usage: $0 [--env conf/site.env]   (asks for each value; Enter keeps the default)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) sed -n '4,7p' "$0"; exit 0 ;; "") ;; *) die "Unknown option: $1" ;; esac
load_env optional

DEFAULT_NEW_DATA="${DATA_TOP:-/u001/data/as${EPAS_VERSION}}"
DEFAULT_OLD_DATA="${OLD_DATA_TOP:-$(dirname "$DEFAULT_NEW_DATA")/as${OLD_EPAS_VERSION:-15}}"
DEFAULT_USER="${SYSTEM_USER}"

# --- INTERACTIVE PROMPTS ---
echo "===================================================================="
echo "      EPAS old -> EPAS ${EPAS_VERSION} SSL Configuration Extraction Utility"
echo "===================================================================="

read -r -p "Enter OLD EPAS Data Directory [${DEFAULT_OLD_DATA}]: " INPUT_OLD_DATA
OLD_DATA="${INPUT_OLD_DATA:-$DEFAULT_OLD_DATA}"

read -r -p "Enter NEW EPAS ${EPAS_VERSION} Data Directory [${DEFAULT_NEW_DATA}]: " INPUT_NEW_DATA
NEW_DATA="${INPUT_NEW_DATA:-$DEFAULT_NEW_DATA}"

read -r -p "Enter Postgres System User [${DEFAULT_USER}]: " INPUT_USER
EXPECTED_USER="${INPUT_USER:-$DEFAULT_USER}"

echo "--------------------------------------------------------------------"

OLD_CONF="${OLD_DATA}/postgresql.conf"
OUTPUT_CONF="${NEW_DATA}/conf.d/ssl.conf"

# --- VERIFICATIONS ---
if [ ! -f "$OLD_CONF" ]; then
    echo "[ERROR] Old EPAS configuration file not found at: ${OLD_CONF}" >&2
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

# --- WRITE TO ssl.conf (keep any existing one, e.g. from epas-ssl-setup.sh) ---
if [ -f "$OUTPUT_CONF" ]; then
    BAK="${OUTPUT_CONF}.bak_$(date +%F_%H%M%S)"
    cp -p "$OUTPUT_CONF" "$BAK"
    echo "[INFO] Existing ${OUTPUT_CONF} saved as ${BAK}"
fi
echo "[INFO] Creating ${OUTPUT_CONF}..."

cat <<EOF > "$OUTPUT_CONF"
# ====================================================================
# SSL configuration extracted from ${OLD_CONF}
# NOTE: relative file names (e.g. 'server.crt') were relative to the OLD data directory -
#       copy those files or change them to absolute paths.
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
    chown -R "${EXPECTED_USER}:$(id -gn "$EXPECTED_USER" 2>/dev/null || echo "$EXPECTED_USER")" "$(dirname "$OUTPUT_CONF")"
fi

echo "[SUCCESS] Generated ${OUTPUT_CONF} successfully!"
log_audit "SSL settings migrated from ${OLD_CONF} to ${OUTPUT_CONF}"