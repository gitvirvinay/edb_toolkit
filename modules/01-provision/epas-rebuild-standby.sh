#!/usr/bin/env bash
set -euo pipefail

# Shared start-up: --env handling, config loading, settings summary (lib/common.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env | conf/site.env] [--yes]
Rebuilds THIS node as a standby of PRIMARY_HOST: stops local EPAS, moves DATA_TOP aside to
DATA_TOP_bak_<timestamp>, re-clones with pg_basebackup (optional replication slot), starts it.
Refuses to run if the local EPAS is up and is NOT a standby (i.e. you are on the primary).
Run as: the EPAS OS user (SYSTEM_USER). Config is required (default: conf/site.env in the repo).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required

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

# Never rebuild a running primary: if local EPAS is up, it must be in recovery (a standby).
if "${BINARY_TOP}/bin/pg_ctl" -D "${DATA_TOP}" status >/dev/null 2>&1; then
    IN_RECOVERY=$("${BINARY_TOP}/bin/psql" -p "${PRIMARY_PORT}" -d postgres -XAtc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "unknown")
    if [ "$IN_RECOVERY" = "f" ]; then
        die "Local EPAS in ${DATA_TOP} is running as a PRIMARY (not in recovery). Refusing to rebuild it as a standby."
    elif [ "$IN_RECOVERY" != "t" ]; then
        log_warn "Local EPAS is running but its role could not be checked (pg_is_in_recovery = ${IN_RECOVERY})."
    fi
fi

show_config PRIMARY_HOST PRIMARY_PORT REP_USER USE_REPLICATION_SLOT REP_SLOT_NAME SYSTEM_USER BINARY_TOP DATA_TOP
confirm_or_exit "rebuild $(hostname -s) as a standby of ${PRIMARY_HOST}: stop local EPAS, move ${DATA_TOP} aside, pg_basebackup a fresh copy"

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

# Arm the cleanup only NOW: from here on DATA_TOP is the fresh directory created above, and the
# previous data directory is safe in BACKUP_PATH. (Previously the trap was armed at the top of the
# script, so any early exit - wrong user, unreachable primary - deleted the LIVE data directory.)
STREAM_SUCCESS=0
cleanup() {
    if [ "$STREAM_SUCCESS" -ne 1 ] && [ -d "${DATA_TOP}" ]; then
        log_warn "Stream pipeline broken or incomplete. Removing the partial copy in ${DATA_TOP}${BACKUP_PATH:+ (previous data kept in ${BACKUP_PATH})}"
        rm -rf "${DATA_TOP}"
    fi
}
trap cleanup EXIT INT TERM HUP

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