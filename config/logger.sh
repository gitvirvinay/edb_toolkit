#!/usr/bin/env bash
# Central syslog/audit/file logging utility
# Usage: source config/logger.sh; log_info "message"; log_error "message"

set -euo pipefail

SCRIPT_NAME="${0##*/}"
LOG_FACILITY="local0"
LOG_TAG="edb-toolkit"

# ==========================================
# FILE LOGGING CONFIGURATION
# ==========================================
# You can change this to any absolute path (e.g., "/var/log/edb-toolkit") 
# or keep it relative to where the script is run.
LOG_DIR="/var/log/edb-toolkit"
LOG_FILE="${LOG_DIR}/deploy.log"

# Safe Directory Creation
if [ ! -d "$LOG_DIR" ]; then
    # Use sudo to create the log directory if running as a non-root user
    sudo mkdir -p "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR" || true
fi

# Ensure the log file is writable by the current user running the script
if [ -d "$LOG_DIR" ] && [ ! -f "$LOG_FILE" ]; then
    sudo touch "$LOG_FILE" 2>/dev/null || touch "$LOG_FILE" || true
    sudo chmod 666 "$LOG_FILE" 2>/dev/null || chmod 666 "$LOG_FILE" || true
fi

# ==========================================
# LOGGING ENGINE
# ==========================================
log_raw() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%F %T.%3N')
    
    # Format the log line
    local log_line="[${timestamp}] [${level^^}] [${SCRIPT_NAME}] ${message}"

    # Destination 1: The Console (Standard Output)
    echo "${log_line}"

    # Destination 2: Local Log File (Appended safely if writable)
    if [ -w "$LOG_FILE" ]; then
        echo "${log_line}" >> "$LOG_FILE"
    fi

    # Destination 3: Syslog (OS System Log)
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
    
    local audit_line="[${timestamp}] [AUDIT] [${SCRIPT_NAME}] ${message}"

    # Print to console and file
    echo "${audit_line}"
    if [ -w "$LOG_FILE" ]; then
        echo "${audit_line}" >> "$LOG_FILE"
    fi

    # Log to syslog with specific audit tag
    logger -p "${LOG_FACILITY}.notice" -t "${LOG_TAG}-audit" "[${SCRIPT_NAME}] ${message}" 2>/dev/null || true
}

# Export functions for use in other scripts
export -f log_debug log_info log_warn log_error log_audit