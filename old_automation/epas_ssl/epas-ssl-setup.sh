#!/bin/bash
# ==============================================================================
# CONSOLIDATED EPAS POSTGRES IN-PLACE SSL SETUP & HARDENING EXECUTER
# ==============================================================================
set -e

log() { echo -e "\n=== $1 ==="; }

# --- Step 1: Environment Parameter Hydration ---
# Parse option flags (e.g., --env prod.env)
if [ "$1" == "--env" ]; then
    shift
fi

if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_env_file.env]"
    exit 1
fi
source "$1"

# --- Step 2: Extraction Strategy Selection ---
log "Gathering Deployment Specifications"
echo "Select Processing Mode:"
echo "  1) Parse an existing third-party PEM bundle architecture"
echo "  2) Automatically generate custom self-signed enterprise assets"
read -r -p "Selection [1-2]: " ASSET_MODE

# Create infrastructure scopes
mkdir -p "$SECURITY_TOP" "${DATA_TOP}/conf.d"

if [ "$ASSET_MODE" -eq 1 ]; then
    read -r -p "Enter full path to target PEM bundle file: " INPUT_PEM_BUNDLE
    if [ ! -f "$INPUT_PEM_BUNDLE" ]; then echo "Bundle file missing."; exit 1; fi
    read -s -r -p "Enter server.key decryption password (ENTER if blank): " KEY_PASSPHRASE
    echo ""

    log "Extracting Cryptographic Assets from Bundle"
    awk '/BEGIN(.*)PRIVATE KEY/,/END(.*)PRIVATE KEY/' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/server.key"
    awk '/BEGIN CERTIFICATE/ {c++} c==1 {print} /END CERTIFICATE/ && c==1 {exit}' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/server.crt"
    awk '/BEGIN CERTIFICATE/ {c++} c>1 {print}' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/root_chain.crt"
    awk '/BEGIN CERTIFICATE/ {content=""; inside=1} inside {content=content $0 "\n"} /END CERTIFICATE/ {inside=0} END {printf "%s", content}' "${SECURITY_TOP}/root_chain.crt" > "${SECURITY_TOP}/root.crt"
    cat "${SECURITY_TOP}/server.crt" "${SECURITY_TOP}/root_chain.crt" > "${SECURITY_TOP}/server_chained.crt"

else
    log "Generating Automated Local Crypto Assets"
    KEY_PASSPHRASE="DBAdminSecretPassphrase123!"
    
    # Cleaned trailing 'd' from 4096 key length parameter
    openssl genrsa -out "${SECURITY_TOP}/root.key" 4096
    openssl req -x509 -new -nodes -key "${SECURITY_TOP}/root.key" -sha256 -days 3650 \
      -subj "/C=US/ST=State/L=City/O=Enterprise/CN=CustomRootCA" -out "${SECURITY_TOP}/root.crt"

    openssl genrsa -aes256 -passout pass:"$KEY_PASSPHRASE" -out "${SECURITY_TOP}/server.key" 2048
    openssl req -new -key "${SECURITY_TOP}/server.key" -passin pass:"$KEY_PASSPHRASE" \
      -subj "/C=US/ST=State/L=City/O=Enterprise/CN=${PRIMARY_HOST}" -out "${SECURITY_TOP}/server.csr"
    
    openssl x509 -req -in "${SECURITY_TOP}/server.csr" -CA "${SECURITY_TOP}/root.crt" -CAkey "${SECURITY_TOP}/root.key" \
      -CAcreateserial -out "${SECURITY_TOP}/server_chained.crt" -days 730 -sha256 -passin pass:"$KEY_PASSPHRASE"
    
    rm -f "${SECURITY_TOP}/server.csr" "${SECURITY_TOP}/root.srl"
fi

# --- Step 3: Passphrase Pin Script Infrastructure ---
PASSPHRASE_LINE=""
if [ -n "$KEY_PASSPHRASE" ]; then
    echo "$KEY_PASSPHRASE" > "${SECURITY_TOP}/.passphrase"
    cat << 'EOF' > "${SECURITY_TOP}/get_pin.sh"
#!/bin/bash
cat "$(dirname "$0")/.passphrase"
EOF
    chmod 0400 "${SECURITY_TOP}/.passphrase"
    chmod 0500 "${SECURITY_TOP}/get_pin.sh"
    PASSPHRASE_LINE="ssl_passphrase_command = '${SECURITY_TOP}/get_pin.sh'"
fi

# --- Step 4: Storage Scopes Permission Hardening ---
log "Enforcing Target Layout Permissions"
chmod 0700 "$SECURITY_TOP"
chmod 0644 "${SECURITY_TOP}"/*.crt 2>/dev/null || true
chmod 0600 "${SECURITY_TOP}/server.key"
chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$SECURITY_TOP"

# --- Step 5: Preflight Integration Testing ---
log "Executing Preflight Crypto Validations"
bash ./tests/preflight-check.sh "$SECURITY_TOP"

# --- Step 6: Configuration Template Injection ---
log "Injecting Drop-In Modular Configurations"
PG_CONF="${DATA_TOP}/postgresql.conf"
CUSTOM_SSL_CONF="${DATA_TOP}/conf.d/ssl.conf"

if ! grep -q "include_dir = 'conf.d'" "$PG_CONF"; then
    cat << EOF >> "$PG_CONF"

#------------------------------------------------------------------------------
# MODULAR CONFIGURATION EXTRACTIONS
#------------------------------------------------------------------------------
include_dir = 'conf.d'
EOF
fi

# Corrected spelling to SUBNET_CIDR inside the export list
export SECURITY_TOP PASSPHRASE_LINE SUBNET_CIDR STANDBY_HOST
envsubst '${SECURITY_TOP} ${PASSPHRASE_LINE}' < templates/ssl.conf.template > "$CUSTOM_SSL_CONF"
envsubst '${SUBNET_CIDR} ${STANDBY_HOST}' < templates/pg_hba.conf.template > "${DATA_TOP}/pg_hba.conf"

chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$CUSTOM_SSL_CONF" "${DATA_TOP}/pg_hba.conf"
chmod 0600 "$CUSTOM_SSL_CONF"

# --- Step 7: Restart System Infrastructure Engine ---
log "Restarting Active Database Engine Cluster"
systemctl restart "$SERVICE_NAME"

log "EPAS Cluster SSL Deployment Complete Successfully!"