#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# epas-ssl-setup.sh  —  Encrypted-key, file-based passphrase (Arch 2A)
# Usage:  sudo ./epas-ssl-setup.sh --env config.env [-b /path/to/bundle.pem]
# -----------------------------------------------------------------------------

# --- 1. Parse args (only --env and --bundle) ---------------------------------
ENV_FILE=""
INPUT_PEM_BUNDLE=""

usage() { echo "Usage: $0 --env /path/to/config.env [-b /path/to/bundle.pem]"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)    ENV_FILE="${2:-}"; shift 2 ;;
        -b|--bundle) INPUT_PEM_BUNDLE="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[[ -n "$ENV_FILE" ]] || usage
[[ -f "$ENV_FILE" ]] || { echo "FATAL: Env file not found: $ENV_FILE"; exit 1; }

# --- 2. Load & validate env --------------------------------------------------
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

for v in DATA_TOP SECURITY_TOP SYSTEM_USER SYSTEM_GROUP SERVICE_NAME PRIMARY_PORT PRIMARY_HOST STANDBY_HOST SUBNET_CIDR; do
    [[ -z "${!v:-}" ]] && { echo "FATAL: Missing env var: $v"; exit 1; }
done

# --- 3. Bundle path ----------------------------------------------------------
if [[ -z "$INPUT_PEM_BUNDLE" ]]; then
    read -r -p "Enter full path to PEM bundle: " INPUT_PEM_BUNDLE
fi
[[ -f "$INPUT_PEM_BUNDLE" ]] || { echo "FATAL: Bundle not found: $INPUT_PEM_BUNDLE"; exit 1; }

# --- 4. Prep directories & backup bucket -------------------------------------
mkdir -p "$SECURITY_TOP" "${DATA_TOP}/conf.d"
chmod 0700 "$SECURITY_TOP"

BACKUP_DIR="${SECURITY_TOP}/.backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
backup() { [[ -e "$1" ]] && cp -a "$1" "$BACKUP_DIR/"; }

# --- 5. Extract private key & enforce encryption -----------------------------
echo "Extracting private key from bundle..."
awk '/-BEGIN .*PRIVATE KEY-/,/-END .*PRIVATE KEY-/' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/server.key.tmp"

# If openssl can read it WITHOUT a passphrase, it is unencrypted → reject
if openssl pkey -in "${SECURITY_TOP}/server.key.tmp" -noout 2>/dev/null; then
    rm -f "${SECURITY_TOP}/server.key.tmp"
    echo "FATAL: Private key is NOT encrypted. This script requires an encrypted key."
    exit 1
fi

# --- 6. Prompt for passphrase (mandatory, non-empty, validated) --------------
while true; do
    read -s -r -p "Enter server.key decryption passphrase: " KEY_PASS
    echo
    [[ -n "$KEY_PASS" ]] || { echo "Passphrase cannot be empty. Try again."; continue; }

    if openssl pkey -in "${SECURITY_TOP}/server.key.tmp" -passin pass:"$KEY_PASS" -noout 2>/dev/null; then
        break
    fi
    echo "Incorrect passphrase. Try again."
done

# Keep the encrypted key on disk (never decrypt it)
backup "${SECURITY_TOP}/server.key"
mv "${SECURITY_TOP}/server.key.tmp" "${SECURITY_TOP}/server.key"
chmod 0600 "${SECURITY_TOP}/server.key"

# --- 7. Store passphrase in hidden file --------------------------------------
PASSPHRASE_FILE="${SECURITY_TOP}/.ssl_key_passphrase"
backup "$PASSPHRASE_FILE"

# No trailing newline — OpenSSL and PostgreSQL both prefer it
printf '%s' "$KEY_PASS" > "$PASSPHRASE_FILE"
chmod 0400 "$PASSPHRASE_FILE"
chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$PASSPHRASE_FILE"

# --- 8. Create helper script for PostgreSQL ----------------------------------
PASSPHRASE_CMD="${SECURITY_TOP}/read_passphrase.sh"
backup "$PASSPHRASE_CMD"

cat > "$PASSPHRASE_CMD" <<EOF
#!/bin/sh
exec cat '${PASSPHRASE_FILE}'
EOF
chmod 0500 "$PASSPHRASE_CMD"
chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$PASSPHRASE_CMD"

# --- 9. Extract certificates -------------------------------------------------
echo "Extracting certificates..."

backup "${SECURITY_TOP}/server_chained.crt"
openssl x509 -in "$INPUT_PEM_BUNDLE" -out "${SECURITY_TOP}/server_chained.crt" 2>/dev/null \
    || { echo "FATAL: Failed to extract server certificate"; exit 1; }

backup "${SECURITY_TOP}/root.crt"
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$INPUT_PEM_BUNDLE" || true)
if [[ "$CERT_COUNT" -le 1 ]]; then
    cp "${SECURITY_TOP}/server_chained.crt" "${SECURITY_TOP}/root.crt"
else
    awk '/-BEGIN CERTIFICATE-/{buf=""; keep=1} keep{buf=buf $0 ORS} /-END CERTIFICATE-/{keep=0} END{printf "%s", buf}' \
        "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/root.crt"
fi

chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$SECURITY_TOP"
chmod 0644 "${SECURITY_TOP}/server_chained.crt" "${SECURITY_TOP}/root.crt"

# --- 10. Preflight checks ----------------------------------------------------
echo "Running preflight checks..."

# Verify key matches cert (decrypt on-the-fly to check modulus)
if openssl rsa -in "${SECURITY_TOP}/server.key" -passin file:"$PASSPHRASE_FILE" -noout 2>/dev/null; then
    KEY_MOD=$(openssl rsa -in "${SECURITY_TOP}/server.key" -passin file:"$PASSPHRASE_FILE" -noout -modulus 2>/dev/null | md5sum | awk '{print $1}')
    CERT_MOD=$(openssl x509 -in "${SECURITY_TOP}/server_chained.crt" -noout -modulus 2>/dev/null | md5sum | awk '{print $1}')
    [[ "$KEY_MOD" == "$CERT_MOD" ]] || { echo "FATAL: Private key does not match certificate"; exit 1; }
else
    echo "Skipping RSA modulus check (non-RSA key)"
fi

openssl x509 -in "${SECURITY_TOP}/server_chained.crt" -noout -checkend 0 >/dev/null 2>&1 \
    || { echo "FATAL: Certificate is expired"; exit 1; }

echo "Preflight checks passed."

# --- 11. Generate ssl.conf ---------------------------------------------------
CUSTOM_SSL_CONF="${DATA_TOP}/conf.d/ssl.conf"
backup "$CUSTOM_SSL_CONF"

cat > "$CUSTOM_SSL_CONF" <<EOF
ssl = on
ssl_cert_file = '${SECURITY_TOP}/server_chained.crt'
ssl_key_file = '${SECURITY_TOP}/server.key'
ssl_ca_file = '${SECURITY_TOP}/root.crt'
ssl_passphrase_command = '${PASSPHRASE_CMD}'

ssl_min_protocol_version = 'TLSv1.2'
ssl_ciphers = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384'
ssl_prefer_server_ciphers = on
EOF

chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$CUSTOM_SSL_CONF"
chmod 0644 "$CUSTOM_SSL_CONF"

# --- 12. Generate pg_hba.conf -----------------------------------------------
PG_HBA_CONF="${DATA_TOP}/pg_hba.conf"
backup "$PG_HBA_CONF"

cat > "$PG_HBA_CONF" <<EOF
# Local connections
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Standby / replication (SSL only)
hostssl replication     all             ${STANDBY_HOST}/32      scram-sha-256
hostssl all             all             ${STANDBY_HOST}/32      scram-sha-256

# Subnet-wide SSL enforcement
hostssl all             all             ${SUBNET_CIDR}          scram-sha-256
hostnossl all           all             ${SUBNET_CIDR}          reject
EOF

chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$PG_HBA_CONF"
chmod 0600 "$PG_HBA_CONF"

# --- 13. Validate config & restart -------------------------------------------
echo "Validating configuration..."
PG_CTL=$(command -v pg_ctl 2>/dev/null || command -v pg_ctl17 2>/dev/null || true)
if [[ -n "$PG_CTL" ]]; then
    su - "$SYSTEM_USER" -c "$PG_CTL -D '$DATA_TOP' check" 2>/dev/null || echo "WARNING: pg_ctl check failed, proceeding anyway"
fi

echo "Restarting $SERVICE_NAME..."
systemctl restart "$SERVICE_NAME" || { echo "FATAL: Failed to restart $SERVICE_NAME"; exit 1; }

sleep 2
systemctl is-active --quiet "$SERVICE_NAME" || { echo "FATAL: Service did not start"; exit 1; }

# --- 14. Post-restart SSL verification ---------------------------------------
if command -v psql >/dev/null 2>&1; then
    SSL_STATUS=$(su - "$SYSTEM_USER" -c "psql -p $PRIMARY_PORT -d postgres -Atc \"SHOW ssl;\" 2>/dev/null" || true)
    [[ "$SSL_STATUS" == "on" ]] && echo "SSL is active (ssl = on)" || echo "WARNING: Could not confirm SSL via psql"
else
    echo "psql not available for verification"
fi

# --- 15. Summary -------------------------------------------------------------
cat <<EOF

===============================================================================
EPAS SSL Setup Complete  (Encrypted Key + File Passphrase)
===============================================================================
Backup dir          : $BACKUP_DIR
Encrypted key       : ${SECURITY_TOP}/server.key
Passphrase file     : ${SECURITY_TOP}/.ssl_key_passphrase   (0400 ${SYSTEM_USER})
Helper script       : ${PASSPHRASE_CMD}
SSL config          : $CUSTOM_SSL_CONF
HBA config          : $PG_HBA_CONF
===============================================================================
EOF