#!/usr/bin/env bash
# =============================================================================
# tde-openssl-to-thales-migrate.sh
#
# Migrates an EXISTING TDE-enabled EPAS cluster from an openssl passphrase-based
# wrap/unwrap command to Thales CipherTrust Manager (KMIP).
#
# How it works:
#   1. Stop the database.
#   2. Preflight: verify Thales KMIP encrypt/decrypt roundtrip works.
#   3. Unwrap the current DEK (key.bin) using the OLD openssl command.
#   4. Re-wrap the DEK with Thales KMIP (new key UUID).
#   5. Update data_encryption_key_unwrap_command in postgresql.conf.
#   6. Start the database and verify TDE + data access.
#
# Usage:
#   sudo ./tde-openssl-to-thales-migrate.sh --env /path/to/migrate.env
#
# Required env vars (migrate.env):
#   OLD_TDE_PASSPHRASE  - openssl passphrase currently protecting key.bin
#                         (inject from secrets manager; never hardcode)
#   THALES_HOST         - CipherTrust Manager FQDN or IP
#   THALES_KEY_UUID     - NEW AES-256 key UUID on Thales for re-wrapping
#   THALES_USER         - Thales KMIP username
#   THALES_PASS         - Thales KMIP password
#   THALES_KEYFILE      - client private key (key.pem)
#   THALES_CERTFILE     - client certificate (cert.pem)
#   THALES_CAFILE       - CA certificate (ca.pem)
#   SYSTEM_USER         - DB OS user (e.g., enterprisedb)
#   SYSTEM_GROUP        - DB OS group
#   DATA_TOP            - PGDATA directory
#   EPAS_VERSION        - e.g., 17
#
# Optional:
#   THALES_PORT         - default 5696
#   DSM_DIR             - default /var/lib/edb/dsm
#   PG_ENCRYPTION_DIR   - default ${DATA_TOP}/global/pg_encryption
#   PRIMARY_PORT        - default 5444
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

if [ "${1:-}" == "--env" ]; then shift; fi
if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_migrate.env]"
    exit 1
fi
source "$1"

# ==========================================
# VALIDATION & SAFEGUARDS
# ==========================================
: "${OLD_TDE_PASSPHRASE:?OLD_TDE_PASSPHRASE is unset - inject from secrets manager}"
: "${THALES_HOST:?THALES_HOST is unset}"
: "${THALES_KEY_UUID:?THALES_KEY_UUID is unset}"
: "${THALES_USER:?THALES_USER is unset}"
: "${THALES_PASS:?THALES_PASS is unset}"
: "${THALES_KEYFILE:?THALES_KEYFILE is unset}"
: "${THALES_CERTFILE:?THALES_CERTFILE is unset}"
: "${THALES_CAFILE:?THALES_CAFILE is unset}"
: "${SYSTEM_USER:?SYSTEM_USER is unset}"
: "${SYSTEM_GROUP:?SYSTEM_GROUP is unset}"
: "${DATA_TOP:?DATA_TOP is unset}"
: "${EPAS_VERSION:?EPAS_VERSION is unset}"

THALES_PORT="${THALES_PORT:-5696}"
DSM_DIR="${DSM_DIR:-/var/lib/edb/dsm}"
PG_ENCRYPTION_DIR="${PG_ENCRYPTION_DIR:-${DATA_TOP}/global/pg_encryption}"
PRIMARY_PORT="${PRIMARY_PORT:-5444}"
KEY_BIN="${PG_ENCRYPTION_DIR}/key.bin"
KMIP_CLIENT="/usr/edb/kmip/client/edb_tde_kmip_client.py"
BINARY_TOP="${BINARY_TOP:-/usr/edb/as${EPAS_VERSION}}"
PG_CONF="${DATA_TOP}/postgresql.conf"
BACKUP_DIR="${PG_ENCRYPTION_DIR}/bak_migrate_$(date +%F_%H%M%S)"

[[ -f "$KEY_BIN" ]] || { log_error "key.bin not found at ${KEY_BIN}. Is TDE enabled on this cluster?"; exit 1; }
[[ -f "$PG_CONF" ]]  || { log_error "postgresql.conf not found at ${PG_CONF}"; exit 1; }

# Capture current unwrap command for rollback reference
CURRENT_UNWRAP="$(sudo -u "$SYSTEM_USER" grep 'data_encryption_key_unwrap_command' "$PG_CONF" || true)"
log_info "Current unwrap command: ${CURRENT_UNWRAP}"

log_info "START: Migrating TDE from openssl to Thales CM (UUID=${THALES_KEY_UUID})"

# ==========================================
# STEP 1: STOP THE DATABASE
# ==========================================
log_info "Stopping EPAS ${EPAS_VERSION}..."
if systemctl is-active --quiet "edb-as-${EPAS_VERSION}.service" 2>/dev/null; then
    sudo systemctl stop "edb-as-${EPAS_VERSION}.service"
elif systemctl is-active --quiet "postgresql-${EPAS_VERSION}" 2>/dev/null; then
    sudo systemctl stop "postgresql-${EPAS_VERSION}"
else
    sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/pg_ctl" -D "$DATA_TOP" -m fast stop
fi

# Confirm fully down
for i in {1..12}; do
    if ! pgrep -f "postgres.*${DATA_TOP}" &>/dev/null; then break; fi
    sleep 2
done
pgrep -f "postgres.*${DATA_TOP}" &>/dev/null && { log_error "Database still running. Aborting."; exit 1; }
log_info "Database stopped."

# ==========================================
# STEP 2: INSTALL & STAGE THALES ARTIFACTS
# ==========================================
log_info "Ensuring KMIP packages are installed..."
for pkg in "python3-pykmip" "edb-tde-kmip-client"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        sudo dnf install -y "$pkg" || { log_error "Failed to install $pkg"; exit 1; }
    fi
done
[[ -f "$KMIP_CLIENT" ]] || { log_error "$KMIP_CLIENT not found"; exit 1; }

log_info "Staging certificates to ${DSM_DIR}/"
sudo mkdir -p "$DSM_DIR"
sudo chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$DSM_DIR"
sudo chmod 0700 "$DSM_DIR"
sudo install -m 0600 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_KEYFILE"  "${DSM_DIR}/key.pem"
sudo install -m 0644 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_CERTFILE" "${DSM_DIR}/cert.pem"
sudo install -m 0644 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$THALES_CAFILE"   "${DSM_DIR}/ca.pem"

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
# STEP 3: PREFLIGHT THALES ROUNDTRIP
# ==========================================
log_info "Preflight: testing Thales KMIP roundtrip..."
TEST_PLAINTEXT="epas-tde-migrate-$(date +%s)"
TEST_CIPHER="/tmp/edb_tde_migrate_test.bin"

printf '%s' "$TEST_PLAINTEXT" | sudo -u "$SYSTEM_USER" python3 "$KMIP_CLIENT" encrypt \
    --out-file="$TEST_CIPHER" \
    --pykmip-config-file="${DSM_DIR}/pykmip.conf" \
    --key-uid="${THALES_KEY_UUID}" \
    --variant=thales || { log_error "Thales encrypt preflight FAILED. Aborting before touching key.bin."; exit 1; }

DECRYPTED="$(sudo -u "$SYSTEM_USER" python3 "$KMIP_CLIENT" decrypt \
    --in-file="$TEST_CIPHER" \
    --pykmip-config-file="${DSM_DIR}/pykmip.conf" \
    --key-uid="${THALES_KEY_UUID}" \
    --variant=thales 2>/dev/null)"
rm -f "$TEST_CIPHER"

[[ "$DECRYPTED" == "$TEST_PLAINTEXT" ]] || { log_error "Thales decrypt roundtrip MISMATCH. Aborting."; exit 1; }
log_info "Thales roundtrip verified OK."

# ==========================================
# STEP 4: UNWRAP OLD -> RE-WRAP WITH THALES
# ==========================================
log_info "Unwrapping DEK with OLD openssl command..."
DEK_PLAINTEXT="$(openssl enc -d -aes-256-cbc -pass pass:"${OLD_TDE_PASSPHRASE}" -in "$KEY_BIN" 2>/dev/null)" \
    || { log_error "Failed to unwrap key.bin with openssl passphrase. WRONG PASSPHRASE?"; exit 1; }
[[ -n "$DEK_PLAINTEXT" ]] || { log_error "Unwrapped DEK is empty. Aborting."; exit 1; }
log_info "DEK unwrapped successfully (${#DEK_PLAINTEXT} bytes)."

log_info "Backing up key.bin and postgresql.conf to ${BACKUP_DIR}/"
sudo mkdir -p "$BACKUP_DIR"
sudo cp -a "$KEY_BIN" "${BACKUP_DIR}/key.bin.openssl"
sudo cp -a "$PG_CONF" "${BACKUP_DIR}/postgresql.conf.bak"

log_info "Re-wrapping DEK with Thales KMIP key ${THALES_KEY_UUID}..."
printf '%s' "$DEK_PLAINTEXT" | sudo -u "$SYSTEM_USER" python3 "$KMIP_CLIENT" encrypt \
    --out-file="$KEY_BIN" \
    --pykmip-config-file="${DSM_DIR}/pykmip.conf" \
    --key-uid="${THALES_KEY_UUID}" \
    --variant=thales || { log_error "Thales re-wrap of DEK FAILED. key.bin untouched (backup at ${BACKUP_DIR})."; exit 1; }
unset DEK_PLAINTEXT
log_info "DEK re-wrapped with Thales."

# ==========================================
# STEP 5: UPDATE postgresql.conf UNWRAP COMMAND
# ==========================================
NEW_UNWRAP_CMD="python3 ${KMIP_CLIENT} decrypt --pykmip-config-file=${DSM_DIR}/pykmip.conf --key-uid=${THALES_KEY_UUID} --in-file=%p --variant=thales"

log_info "Updating data_encryption_key_unwrap_command in postgresql.conf..."
# idempotent: comment out any old line, append new one
sudo -u "$SYSTEM_USER" sed -i.bak_thales "s|^data_encryption_key_unwrap_command *=.*|# &|" "$PG_CONF"
echo "data_encryption_key_unwrap_command = '${NEW_UNWRAP_CMD}'" \
    | sudo -u "$SYSTEM_USER" tee -a "$PG_CONF" > /dev/null

# ==========================================
# STEP 6: START & VERIFY
# ==========================================
log_info "Starting database with new Thales unwrap command..."
if systemctl list-unit-files 2>/dev/null | grep -q "^edb-as-${EPAS_VERSION}.service"; then
    sudo systemctl start "edb-as-${EPAS_VERSION}.service"
elif systemctl list-unit-files 2>/dev/null | grep -q "^postgresql-${EPAS_VERSION}"; then
    sudo systemctl start "postgresql-${EPAS_VERSION}"
else
    sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/pg_ctl" -D "$DATA_TOP" -l "${DATA_TOP}/logfile" start
fi

log_info "Waiting for startup..."
for i in {1..15}; do
    sleep 2
    if sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/pg_isready" -p "$PRIMARY_PORT" -q 2>/dev/null; then break; fi
done

# Verify unwrap actually worked (server came up = unwrap succeeded)
if ! sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/pg_isready" -p "$PRIMARY_PORT" -q 2>/dev/null; then
    log_error "Database did NOT start. New Thales unwrap command may be wrong."
    log_error "ROLLBACK: sudo systemctl stop <svc>; cp ${BACKUP_DIR}/key.bin.openssl ${KEY_BIN}; cp ${BACKUP_DIR}/postgresql.conf.bak ${PG_CONF}; start service"
    exit 1
fi

TDE_VER="$(sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/psql" -p "$PRIMARY_PORT" -U "$SYSTEM_USER" -d edb -Atc \
    "SELECT data_encryption_version FROM pg_control_init();" 2>/dev/null || true)"

# Verify actual data is readable (proves DEK unwraps correctly in practice)
DATA_CHECK="$(sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/psql" -p "$PRIMARY_PORT" -U "$SYSTEM_USER" -d edb -Atc \
    "SELECT count(*) FROM pg_database;" 2>/dev/null || true)"

if [[ "$TDE_VER" == "1" && -n "$DATA_CHECK" ]]; then
    log_info "SUCCESS: Migration complete. TDE active (version=${TDE_VER}), data readable (${DATA_CHECK} databases)."
    log_info "Old openssl-wrapped key preserved at ${BACKUP_DIR}/key.bin.openssl"
else
    log_error "Verification failed (TDE=${TDE_VER}). Investigate; rollback artifacts in ${BACKUP_DIR}."
    exit 1
fi
