#!/usr/bin/env bash
set -euo pipefail

# Source central logger
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

STREAM_SUCCESS=0
cleanup() {
    if [ "$STREAM_SUCCESS" -ne 1 ] && [ -d "${DATA_TOP}" ]; then
        log_warn "Stream pipeline broken or incomplete. Purging target node layout: ${DATA_TOP}"
        # We use sudo here to guarantee we can purge a root-owned directory if creation gets stuck
        sudo rm -rf "${DATA_TOP}"
    fi
}
trap cleanup EXIT INT TERM HUP

if [ "${1:-}" == "--env" ]; then shift; fi
if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_cluster.env]"
    exit 1
fi
source "$1"

# Ensure variables with no safe default are bound (avoids 'set -u' crash)
: "${SYSTEM_USER:?SYSTEM_USER variable is unset}"
: "${SYSTEM_GROUP:?SYSTEM_GROUP variable is unset}"
: "${PRIMARY_PORT:?PRIMARY_PORT variable is unset}"
: "${PRIMARY_HOST:?PRIMARY_HOST variable is unset}"
: "${REP_USER:?REP_USER variable is unset}"
: "${REP_SLOT_NAME:?REP_SLOT_NAME variable is unset}"

[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Invalid SERVICE_NAME"; exit 1; }

# ==========================================
# [0/4] VALIDATING REPLICATION SLOT
# ==========================================
log_info "[0/4] Validating Replication Slot on Primary"

# Execute psql as the SYSTEM_USER so local socket connections or OS ident mapping work smoothly
SLOT_EXISTS=$(sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/psql" -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REP_USER}" -d postgres \
    -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name='${REP_SLOT_NAME}';" 2>/dev/null || echo "0")

if [ "$SLOT_EXISTS" != "1" ]; then
    log_warn "Replication slot '${REP_SLOT_NAME}' does not exist on primary. Creating..."
    sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/psql" -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REP_USER}" -d postgres \
        -c "SELECT pg_create_physical_replication_slot('${REP_SLOT_NAME}', true);" 2>/dev/null || {
        log_error "Failed to create replication slot. Ensure primary is reachable and REP_USER has REPLICATION privilege."
        exit 1
    }
fi

# ==========================================
# [1/4] ISOLATING TARGET NODE
# ==========================================
log_info "[1/4] Safely Isolating Local Target Node"
sudo /bin/systemctl stop "${SERVICE_NAME}"

if [[ -d "${DATA_TOP}" ]]; then
    BACKUP_PATH="${DATA_TOP}_bak_$(date +%F_%H%M%S)"
    log_info "Rotating unaligned data directory into trackable backup: ${BACKUP_PATH}"
    sudo mv "${DATA_TOP}" "${BACKUP_PATH}"
fi

# Create directory cleanly with correct target permissions
sudo mkdir -p "${DATA_TOP}"
sudo chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "${DATA_TOP}"
sudo chmod 700 "${DATA_TOP}"

# ==========================================
# [2/4] PG_BASEBACKUP STREAM PIPELINE
# ==========================================
log_info "[2/4] Executing pg_basebackup Stream Pipeline"

# Execute as SYSTEM_USER so the files streamed down are natively owned by the system user
sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/pg_basebackup" \
    -h "${PRIMARY_HOST}" \
    -p "${PRIMARY_PORT}" \
    -U "${REP_USER}" \
    -D "${DATA_TOP}" \
    --slot="${REP_SLOT_NAME}" \
    -Fp -Xs -P -R -v

# ==========================================
# [3/4] VERIFYING RECOVERY ANCHORS
# ==========================================
log_info "[3/4] Verifying Recovery Anchors"
if [[ ! -f "${DATA_TOP}/standby.signal" ]]; then
    log_error "standby.signal was not generated."
    exit 1
fi

# Flip the success marker safely before the trap block unbinds
STREAM_SUCCESS=1

# ==========================================
# [4/4] STARTING STANDBY
# ==========================================
log_info "[4/4] Starting Rebuilt Standby Cluster"
sudo /bin/systemctl start "${SERVICE_NAME}"
sudo /bin/systemctl status "${SERVICE_NAME}" --no-pager

log_audit "Standby rebuild completed successfully using slot: ${REP_SLOT_NAME}"