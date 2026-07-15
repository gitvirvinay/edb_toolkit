#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

ASSET_MODE=""
INPUT_PEM_BUNDLE=""
KEY_PASS=""

# Parse input flags to prevent headless terminal locking during pipeline tasks
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--mode) ASSET_MODE="$2"; shift 2 ;;
        -b|--bundle) INPUT_PEM_BUNDLE="$2"; shift 2 ;;
        --env) source "$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [ -z "${DATA_TOP:-}" ]; then
    echo "Usage: $0 --env path_to_config.env [-m mode] [-b bundle_path]"
    exit 1
fi

mkdir -p "$SECURITY_TOP" "${DATA_TOP}/conf.d"

# Fallback to interactive interface only if processing flags are missing
if [ -z "$ASSET_MODE" ]; then
    echo "Select Processing Mode:"
    echo "  1) Parse an existing third-party PEM bundle architecture"
    echo "  2) Automatically generate custom self-signed enterprise assets"
    read -r -p "Selection [1-2]: " ASSET_MODE
fi

if [ "$ASSET_MODE" -eq 1 ]; then
    if [ -z "$INPUT_PEM_BUNDLE" ]; then
        read -r -p "Enter full path to target PEM bundle file: " INPUT_PEM_BUNDLE
    fi
    if [ ! -f "$INPUT_PEM_BUNDLE" ]; then echo "Bundle file missing."; exit 1; fi
    
    if [ -t 0 ]; then
        read -s -r -p "Enter server.key decryption password (ENTER if blank): " KEY_PASS; echo ""
    fi

    if [ -n "$KEY_PASS" ]; then
        openssl rsa -in "$INPUT_PEM_BUNDLE" -passin pass:"$KEY_PASS" -out "${SECURITY_TOP}/server.key" 2>/dev/null
        PASSPHRASE_CMD="${SECURITY_TOP}/read_passphrase.sh"
        printf '#!/bin/sh\nexec sudo /bin/systemd-ask-password --no-tty "Enter SSL key passphrase:"\n' > "$PASSPHRASE_CMD"
        chmod 0500 "$PASSPHRASE_CMD"
        PASSPHRASE_LINE="ssl_passphrase_command = '$PASSPHRASE_CMD'"
    else
        openssl rsa -in "$INPUT_PEM_BUNDLE" -out "${SECURITY_TOP}/server.key" 2>/dev/null
        PASSPHRASE_LINE=""
    fi
    openssl x509 -in "$INPUT_PEM_BUNDLE" -out "${SECURITY_TOP}/server_chained.crt"
    awk '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/root.crt"
else
    log_info "Generating Corporate Internal Self-Signed Pair"
    PASSPHRASE_LINE=""
    openssl req -new -x509 -days 365 -nodes -text -out "${SECURITY_TOP}/server_chained.crt" \
      -keyout "${SECURITY_TOP}/server.key" -subj "/CN=$(hostname -f)"
    cp "${SECURITY_TOP}/server_chained.crt" "${SECURITY_TOP}/root.crt"
fi

chmod 0700 "$SECURITY_TOP"
chmod 0600 "${SECURITY_TOP}/server.key"
chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$SECURITY_TOP"

log_info "Executing Preflight Crypto Validations"
./tests/preflight-check.sh "$SECURITY_TOP" || { log_error "Preflight checks failed!"; exit 1; }

CUSTOM_SSL_CONF="${DATA_TOP}/conf.d/ssl.conf"
export SECURITY_TOP PASSPHRASE_LINE SUBNET_CIDR STANDBY_HOST
envsubst '${SECURITY_TOP} ${PASSPHRASE_LINE}' < templates/ssl.conf.template > "$CUSTOM_SSL_CONF"
envsubst '${SUBNET_CIDR} ${STANDBY_HOST}' < templates/pg_hba.conf.template > "${DATA_TOP}/pg_hba.conf"

log_info "Restarting Cluster Engine (HBA changes require restart)"
sudo systemctl restart "$SERVICE_NAME"

./tests/verify-db-ssl.sh "${BASH_ARGV[0]:-}"
