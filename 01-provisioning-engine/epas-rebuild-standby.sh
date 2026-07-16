#!/usr/bin/env bash
set -euo pipefail

# Source central logger
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

# Ensure variables with no safe default are bound (avoids 'set -u' crash)
: "${SYSTEM_USER:?SYSTEM_USER variable is unset}"
: "${PRIMARY_PORT:?PRIMARY_PORT variable is unset}"
: "${PRIMARY_HOST:?PRIMARY_HOST variable is unset}"
: "${REP_USER:?REP_USER variable is unset}"
: "${DATA_TOP:?DATA_TOP variable is unset}"
: "${BINARY_TOP:?BINARY_TOP variable is unset}"

# Default to using replication slots if the parameter is not explicitly defined in the env file
USE_REPLICATION_SLOT="${USE_REPLICATION_SLOT:-true}"

# Only validate REP_SLOT_NAME if slots are actively enabled
if [ "${USE_REPLICATION_SLOT}" = "true" ]; then
    : "${REP_SLOT_NAME:?REP_SLOT_NAME variable is unset when USE_REPLICATION_SLOT is true}"
fi

# ==========================================
# SAFEGUARDS & USER VALIDATION
# ==========================================
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "$SYSTEM_USER" ]; then
    log_error "This script must be run directly as the system user: '${SYSTEM_USER}'."
    log_error "Please switch user: 'sudo su - ${SYSTEM_USER}' and execute again."
    exit 1
fi

# ==========================================
# [0/4] VALIDATING REPLICATION SLOT (IF ENABLED)
# ==========================================
if [ "${USE_REPLICATION_SLOT}" = "true" ]; then
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
else
    log_info "[0/4] Skipping replication slot check (USE_REPLICATION_SLOT is set to false)."
fi

# ==========================================
# [1/4] ISOLATING TARGET NODE (USING PG_CTL)
# ==========================================
log_info "[1/4] Safely Stopping Local Target Node via pg_ctl"

# Stop the database cleanly. If it is already stopped, pg_ctl handles it gracefully.
if "${BINARY_TOP}/bin/pg_ctl" -D "${DATA_TOP}" status >/dev/null 2>&1; then
    log_info "Active database instance detected. Shutting down..."
    "${BINARY_TOP}/bin/pg_ctl" -D "${DATA_TOP}" stop -m fast
else
    log_info "No active database instance detected on ${DATA_TOP}."
fi

if [[ -d "${DATA_TOP}" ]]; then
    BACKUP_PATH="${DATA_TOP}_bak_$(date +%F_%H%M%S)"
    log_info "Rotating unaligned data directory into trackable backup: ${BACKUP_PATH}"
    mv "${DATA_TOP}" "${BACKUP_PATH}"
fi

# Create directory cleanly
mkdir -p "${DATA_TOP}"
chmod 700 "${DATA_TOP}"

# ==========================================
# [2/4] PG_BASEBACKUP STREAM PIPELINE
# ==========================================
log_info "[2/4] Executing pg_basebackup Stream Pipeline"

# Dynamically construct the backup command arguments based on slot usage
declare -a BASEBACKUP_ARGS=(
    "-h" "${PRIMARY_HOST}"
    "-p" "${PRIMARY_PORT}"
    "-U" "${REP_USER}"
    "-D" "${DATA_TOP}"
    "-Fp" "-Xs" "-P" "-R" "-v"
)

if [ "${USE_REPLICATION_SLOT}" = "true" ]; then
    BASEBACKUP_ARGS+=("--slot=${REP_SLOT_NAME}")
fi

# Execute pg_basebackup cleanly using constructed arguments array
"${BINARY_TOP}/bin/pg_basebackup" "${BASEBACKUP_ARGS[@]}"

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
# [4/4] STARTING STANDBY (USING PG_CTL)
# ==========================================
log_info "[4/4] Starting Rebuilt Standby Cluster via pg_ctl"

# Start the cluster and wait for it to fully initialize
"${BINARY_TOP}/bin/pg_ctl" -D "${DATA_TOP}" start -w

# Log the status to verify it is successfully running in standby/recovery mode
"${BINARY_TOP}/bin/pg_ctl" -D "${DATA_TOP}" status

if [ "${USE_REPLICATION_SLOT}" = "true" ]; then
    log_audit "Standby rebuild completed successfully using slot: ${REP_SLOT_NAME}"
else
    log_audit "Standby rebuild completed successfully (without replication slot)"
fi