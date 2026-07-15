#!/usr/bin/env bash
# Central syslog/audit logging utility
# Usage: source config/logger.sh; log_info "message"; log_error "message"

set -euo pipefail

SCRIPT_NAME="${0##*/}"
LOG_FACILITY="local0"
LOG_TAG="edb-toolkit"

log_raw() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%F %T.%3N')
    echo "[${timestamp}] [${level}] [${SCRIPT_NAME}] ${message}"
    logger -p "${LOG_FACILITY}.${level}" -t "${LOG_TAG}" "[${SCRIPT_NAME}] ${message}" 2>/dev/null || true
}

log_debug() { log_raw "debug" "$@"; }
log_info()  { log_raw "info"  "$@"; }
log_warn()  { log_raw "warn"  "$@"; }
log_error() { log_raw "err"   "$@"; }
log_audit() {
    local message="$*"
    local timestamp
    timestamp=$(date '+%F %T.%3N')
    echo "[${timestamp}] [AUDIT] [${SCRIPT_NAME}] ${message}"
    logger -p "${LOG_FACILITY}.notice" -t "${LOG_TAG}-audit" "[${SCRIPT_NAME}] ${message}" 2>/dev/null || true
}

# Export functions for use in other scripts
export -f log_debug log_info log_warn log_error log_audit
