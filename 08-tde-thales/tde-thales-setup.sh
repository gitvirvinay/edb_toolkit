#!/usr/bin/env bash
# =============================================================================
# tde-thales-setup.sh
#
# Automates EPAS TDE integration with Thales CipherTrust Manager (KMIP method)
# on RHEL 9. Must run BEFORE initdb (TDE cannot be enabled on an existing
# cluster).
#
# Usage:
#   sudo ./tde-thales-setup.sh --env /path/to/deploy.env
#
# Required env vars (deploy.env):
#   THALES_HOST        - CipherTrust Manager FQDN or IP
#   THALES_KEY_UUID    - UUID of the AES-256 key created on Thales CM
#   THALES_USER        - Thales KMIP username
#   THALES_PASS        - Thales KMIP password
#   THALES_KEYFILE     - path to client private key (key.pem)
#   THALES_CERTFILE    - path to client certificate (cert.pem)
#   THALES_CAFILE      - path to CA certificate (ca.pem)
#   SYSTEM_USER        - DB OS user (e.g., enterprisedb)
#   DATA_TOP           - PGDATA directory (e.g., /var/lib/edb-as/17/data)
#   EPAS_VERSION       - e.g., 17
#
# Optional:
#   THALES_PORT        - default 5696
#   DSM_DIR            - where pykmip.conf lives, default /var/lib/edb/dsm
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

if [ "${1:-}" == "--env" ]; then shift; fi
if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_deploy.env]"
    exit 1
fi
source "$1"

# ==========================================
# VALIDATION & SAFEGUARDS
# ==========================================
: "${THALES_HOST:?THALES_HOST is unset}"
: "${THALES_KEY_UUID:?THALES_KEY_UUID is unset}"
: "${THALES_USER:?THALES_USER is unset}"
: "${THALES_PASS:?THALES_PASS is unset - inject from secrets manager}"
: "${THALES_KEYFILE:?THALES_KEYFILE is unset}"
: "${THALES_CERTFILE:?THALES_CERTFILE is unset}"
: "${THALES_CAFILE:?THALES_CAFILE is unset}"
: "${SYSTEM_USER:?SYSTEM_USER is unset}"
: "${SYSTEM_GROUP:?SYSTEM_GROUP is unset}"
: "${DATA_TOP:?DATA_TOP is unset}"
: "${EPAS_VERSION:?EPAS_VERSION is unset}"

THALES_PORT="${THALES_PORT:-5696}"
DSM_DIR="${DSM_DIR:-/var/lib/edb/dsm}"
KMIP_CLIENT="/usr/edb/kmip/client/edb_tde_kmip_client.py"
BINARY_TOP="${BINARY_TOP:-/usr/edb/as${EPAS_VERSION}}"

# Guard: refuse to run if cluster already exists without TDE
if [ -f "${DATA_TOP}/PG_VERSION" ]; then
    if ! sudo -u "$SYSTEM_USER" grep -q "data_encryption_key_unwrap_command" "${DATA_TOP}/postgresql.conf" 2>/dev/null; then
        log_error "Cluster already initialized WITHOUT TDE. TDE must be enabled at initdb time."
        exit 1
    fi
    log_info "Cluster already TDE-enabled. Nothing to do."
    exit 0
fi

log_info "START: Thales CM TDE setup for EPAS ${EPAS_VERSION} (host=${THALES_HOST}, UUID=${THALES_KEY_UUID})"

# ==========================================
# STEP 1: INSTALL PACKAGES
# ==========================================
log_info "Ensuring KMIP packages are installed..."
for pkg in "python3-pykmip" "edb-tde-kmip-client"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        sudo dnf install -y "$pkg" || { log_error "Failed to install $pkg"; exit 1; }
    fi
done

[[ -f "$KMIP_CLIENT" ]] || { log_error "$KMIP_CLIENT not found after package install"; exit 1; }

# ==========================================
# STEP 2: STAGE CERTIFICATES & pykmip.conf
# ==========================================
log_info "Staging client certificates to ${DSM_DIR}/"
sudo mkdir -p "$DSM_DIR"
sudo chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$DSM_DIR"
sudo chmod 0700 "$DSM_DIR"

for f in "$THALES_KEYFILE" "$THALES_CERTFILE" "$THALES_CAFILE"; do
    [[ -f "$f" ]] || { log_error "Certificate file not found: $f"; exit 1; }
done

sudo install -m 0600 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_KEYFILE"  "${DSM_DIR}/key.pem"
sudo install -m 0644 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_CERTFILE" "${DSM_DIR}/cert.pem"
sudo install -m 0644 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_CAFILE"   "${DSM_DIR}/ca.pem"

log_info "Writing ${DSM_DIR}/pykmip.conf"
cat << PYKMIP_EOF | sudo -u "$SYSTEM_USER" tee "${DSM_DIR}/pykmip.conf" > /dev/null
[client]
host=${THALES_HOST}
port=${THALES_PORT}
username=${THALES_USER}
password=${THALES_PASS}
keyfile=${DSM_DIR}/key.pem
certfile=${DSM_DIR}/cert.pem
ca_certs=${DSM_DIR}/ca.pem
PYKMIP_EOF
sudo chmod 0600 "${DSM_DIR}/pykmip.conf"

# ==========================================
# STEP 3: VERIFY KMIP ENCRYPT/DECRYPT ROUNDTRIP
# ==========================================
log_info "Testing KMIP encrypt/decrypt roundtrip against Thales CM..."
TEST_PLAINTEXT="epas-tde-preflight-$(date +%s)"
TEST_CIPHER="/tmp/edb_tde_preflight.bin"

if ! printf '%s' "$TEST_PLAINTEXT" | sudo -u "$SYSTEM_USER" python3 "$KMIP_CLIENT" encrypt \
        --out-file="$TEST_CIPHER" \
        --pykmip-config-file="${DSM_DIR}/pykmip.conf" \
        --key-uid="${THALES_KEY_UUID}" \
        --variant=thales; then
    log_error "KMIP encrypt test FAILED. Check host/port/certs/UUID."
    exit 1
fi

DECRYPTED="$(sudo -u "$SYSTEM_USER" python3 "$KMIP_CLIENT" decrypt \
    --in-file="$TEST_CIPHER" \
    --pykmip-config-file="${DSM_DIR}/pykmip.conf" \
    --key-uid="${THALES_KEY_UUID}" \
    --variant=thales 2>/dev/null)"

rm -f "$TEST_CIPHER"

if [[ "$DECRYPTED" != "$TEST_PLAINTEXT" ]]; then
    log_error "KMIP decrypt roundtrip MISMATCH. Aborting before initdb."
    exit 1
fi
log_info "KMIP roundtrip verified OK."

# ==========================================
# STEP 4: EXPORT WRAP/UNWRAP COMMANDS FOR initdb
# ==========================================
export PGDATAKEYWRAPCMD="python3 ${KMIP_CLIENT} encrypt --pykmip-config-file=${DSM_DIR}/pykmip.conf --key-uid=${THALES_KEY_UUID} --out-file=%p --variant=thales"
export PGDATAKEYUNWRAPCMD="python3 ${KMIP_CLIENT} decrypt --pykmip-config-file=${DSM_DIR}/pykmip.conf --key-uid=${THALES_KEY_UUID} --in-file=%p --variant=thales"

log_info "PGDATAKEYWRAPCMD   = ${PGDATAKEYWRAPCMD}"
log_info "PGDATAKEYUNWRAPCMD = ${PGDATAKEYUNWRAPCMD}"

# ==========================================
# STEP 5: INITIALIZE TDE-ENABLED CLUSTER
# ==========================================
log_info "Running initdb with TDE (-D ${DATA_TOP})..."
sudo mkdir -p "$DATA_TOP"
sudo chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$DATA_TOP"

sudo -u "$SYSTEM_USER" -E "${BINARY_TOP}/bin/initdb" \
    -D "$DATA_TOP" -E UTF8 -U "$SYSTEM_USER" --data-encryption=256

# Confirm initdb persisted the unwrap command
if ! sudo -u "$SYSTEM_USER" grep -q "data_encryption_key_unwrap_command" "${DATA_TOP}/postgresql.conf"; then
    log_warn "unwrap command missing from postgresql.conf; injecting manually."
    echo "data_encryption_key_unwrap_command = '${PGDATAKEYUNWRAPCMD}'" \
        | sudo -u "$SYSTEM_USER" tee -a "${DATA_TOP}/postgresql.conf" > /dev/null
fi

# ==========================================
# STEP 6: START & VERIFY
# ==========================================
log_info "Starting database..."
if command -v systemctl &>/dev/null && systemctl list-unit-files | grep -q "^edb-as-${EPAS_VERSION}.service"; then
    sudo systemctl enable --now "edb-as-${EPAS_VERSION}.service"
else
    sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/pg_ctl" -D "$DATA_TOP" -l "${DATA_TOP}/logfile" start
fi

log_info "Verifying TDE status..."
sleep 3
TDE_VER="$(sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/psql" -p "${PRIMARY_PORT:-5444}" -U "$SYSTEM_USER" -d edb -Atc \
    "SELECT data_encryption_version FROM pg_control_init();" 2>/dev/null || true)"

if [[ "$TDE_VER" == "1" ]]; then
    log_info "SUCCESS: TDE is ACTIVE (data_encryption_version=${TDE_VER})"
else
    log_error "TDE verification returned '${TDE_VER}'. Investigate manually."
    exit 1
fi

log_info "DONE: EPAS ${EPAS_VERSION} cluster initialized with Thales CM TDE."
