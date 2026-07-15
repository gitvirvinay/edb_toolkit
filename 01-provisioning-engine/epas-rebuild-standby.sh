#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

STREAM_SUCCESS=0
cleanup() {
    if [ "$STREAM_SUCCESS" -ne 1 ] && [ -d "${DATA_TOP}" ]; then
        log_warn "Stream pipeline broken or incomplete. Purging target node layout: ${DATA_TOP}"
        rm -rf "${DATA_TOP}"
    fi
}
trap cleanup EXIT INT TERM HUP

if [ "${1:-}" == "--env" ]; then shift; fi
if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_cluster.env]"
    exit 1
fi
source "$1"

CURRENT_USER=$(whoami)
if [[ "${CURRENT_USER}" != "${SYSTEM_USER}" ]]; then
    log_error "This script must be executed as the '${SYSTEM_USER}' user."
    exit 1
fi

[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Invalid SERVICE_NAME"; exit 1; }

log_info "[0/4] Validating Replication Slot on Primary"
SLOT_EXISTS=$("${BINARY_TOP}/bin/psql" -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REP_USER}" -d postgres \
    -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name='${REP_SLOT_NAME}';" 2>/dev/null || echo "0")

if [ "$SLOT_EXISTS" != "1" ]; then
    log_warn "Replication slot '${REP_SLOT_NAME}' does not exist on primary. Creating..."
    "${BINARY_TOP}/bin/psql" -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REP_USER}" -d postgres \
        -c "SELECT pg_create_physical_replication_slot('${REP_SLOT_NAME}', true);" 2>/dev/null || {
        log_error "Failed to create replication slot. Ensure primary is reachable and REP_USER has REPLICATION privilege."
        exit 1
    }
fi

log_info "[1/4] Safely Isolating Local Target Node"
sudo /bin/systemctl stop "${SERVICE_NAME}"

if [[ -d "${DATA_TOP}" ]]; then
    BACKUP_PATH="${DATA_TOP}_bak_$(date +%F_%H%M%S)"
    log_info "Rotating unaligned data directory into trackable backup: ${BACKUP_PATH}"
    mv "${DATA_TOP}" "${BACKUP_PATH}"
fi
mkdir -p "${DATA_TOP}"
chmod 700 "${DATA_TOP}"

log_info "[2/4] Executing pg_basebackup Stream Pipeline"
"${BINARY_TOP}/bin/pg_basebackup" \
    -h "${PRIMARY_HOST}" \
    -p "${PRIMARY_PORT}" \
    -U "${REP_USER}" \
    -D "${DATA_TOP}" \
    --slot="${REP_SLOT_NAME}" \
    -Fp -Xs -P -R -v

log_info "[3/4] Verifying Recovery Anchors"
if [[ ! -f "${DATA_TOP}/standby.signal" ]]; then
    log_error "standby.signal was not generated."
    exit 1
fi

# Flip the success marker safely before the trap block unbinds
STREAM_SUCCESS=1

log_info "[4/4] Starting Rebuilt Standby Cluster"
sudo /bin/systemctl start "${SERVICE_NAME}"
sudo /bin/systemctl status "${SERVICE_NAME}" --no-pager

log_audit "Standby rebuild completed successfully using slot: ${REP_SLOT_NAME}"
