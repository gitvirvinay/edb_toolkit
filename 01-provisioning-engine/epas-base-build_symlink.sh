#!/usr/bin/env bash
set -euo pipefail

# Source central logger
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

if [ "${1:-}" == "--env" ]; then shift; fi
if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_deploy.env]"
    exit 1
fi
source "$1"

# ==========================================
# SAFEGUARDS & VALIDATION
# ==========================================
# Optional: Root Privileges Check (Commented out to support sudo-whitelisted execution)
# if [[ $EUID -ne 0 ]]; then
#    log_error "This script must be run as root (or with sudo privileges)."
#    exit 1
# fi

# Validate critical variables
[[ "$EPAS_VERSION" =~ ^[0-9]+$ ]] || { log_error "EPAS_VERSION must be numeric"; exit 1; }
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Invalid SERVICE_NAME"; exit 1; }

# Ensure variables with no safe default are bound (avoids 'set -u' crash)
: "${SYSTEM_USER:?SYSTEM_USER variable is unset}"
: "${SYSTEM_GROUP:?SYSTEM_GROUP variable is unset}"
: "${PRIMARY_PORT:?PRIMARY_PORT variable is unset}"

log_info "START: EPAS ${EPAS_VERSION} Enterprise Build Infrastructure"
PACKAGE_NAME="edb-as${EPAS_VERSION}-server"

#==========================================
# PACKAGE INSTALLATION (RESILIENT LOOP)
# ==========================================
# Define target packages and extensions
# ==========================================

PACKAGES=(
    "$PACKAGE_NAME"                                # edb-as17-server
    "${PACKAGE_NAME}-edb_wait_states"              # EDB proprietary wait states
	"edb-as${EPAS_VERSION}-query-advisor*"
	"edb-as${EPAS_VERSION}-stat_monitor*"
    "edb-pg${EPAS_VERSION}-pgaudit*"               # Corrected: edb-pg17-pgaudit
    "edb-pg${EPAS_VERSION}-pg-cron*"               # Corrected: edb-pg17-pg_cron
    "pg_repack"              
    "edb-lasso"                                    # Dependency for PWR
    "edb-pwr"                                      # Global utility (if repo enabled)
    "${PACKAGE_NAME}-contrib"
    "${PACKAGE_NAME}-pldebugger"
    "${PACKAGE_NAME}-plpython3"
    "${PACKAGE_NAME}-plperl"
    "${PACKAGE_NAME}-pltcl"
    "${PACKAGE_NAME}-sslutils"
    "${PACKAGE_NAME}-sqlprofiler"
    "${PACKAGE_NAME}-sqlprotect"
)

log_info "Evaluating and installing EPAS system packages..."
FAILED_PACKAGES=()

for pkg in "${PACKAGES[@]}"; do
    if ! sudo dnf list installed "$pkg" &>/dev/null; then
        log_info "Installing package: $pkg"
        if ! sudo dnf install -y "$pkg"; then
            log_warn "Could not install $pkg. Skipping..."
            FAILED_PACKAGES+=("$pkg")
        fi
    fi
done

if [ ${#FAILED_PACKAGES[@]} -ne 0 ]; then
    log_warn "Warning: The following packages could not be installed: ${FAILED_PACKAGES[*]}"
fi

# ==========================================
# BINARY ROTATION, INSTALL & COMPATIBILITY SYMLINK
# ==========================================
# Design:
#   - BINARY_TOP is the single physical copy of the EPAS binaries.
#   - /usr/edb/as${EPAS_VERSION} is only a compatibility symlink to BINARY_TOP.
#   - This avoids maintaining two physical EPAS installations.
#
# Example:
#   BINARY_TOP=/u001/binary/as17
#   /usr/edb/as17 -> /u001/binary/as17
# ==========================================
log_info "Configuring EPAS binary location: ${BINARY_TOP}"
log_info "Compatibility path: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"

sudo mkdir -p "$DATA_TOP"

# BINARY_TOP may already be the target of SRC_BINARY_DIR.
# Do not rotate/copy anything in that case.
if [[ -L "$SRC_BINARY_DIR" ]]; then
    CURRENT_TARGET="$(readlink -f "$SRC_BINARY_DIR" 2>/dev/null || true)"
    EXPECTED_TARGET="$(readlink -f "$BINARY_TOP" 2>/dev/null || true)"

    if [[ "$CURRENT_TARGET" == "$EXPECTED_TARGET" && -d "$BINARY_TOP/bin" ]]; then
        log_info "${SRC_BINARY_DIR} already points to ${BINARY_TOP}; no binary copy required."
    else
        log_warn "${SRC_BINARY_DIR} is a symlink but does not point to ${BINARY_TOP}."
        log_warn "Replacing it with the configured compatibility symlink."
        sudo rm -f "$SRC_BINARY_DIR"
    fi
fi

# If /usr/edb/as${EPAS_VERSION} is still a real package directory,
# migrate its contents to BINARY_TOP before replacing it with the symlink.
if [[ -d "$SRC_BINARY_DIR" && ! -L "$SRC_BINARY_DIR" ]]; then
    sudo mkdir -p "$BINARY_TOP"

    if [[ -d "$BINARY_TOP/bin" ]]; then
        BACKUP_BIN="${BINARY_TOP}_bak_$(date +%F_%H%M%S)"
        log_warn "Existing binaries found in ${BINARY_TOP}. Rotating to ${BACKUP_BIN}"
        sudo mv "$BINARY_TOP" "$BACKUP_BIN"
        sudo mkdir -p "$BINARY_TOP"
    fi

    log_info "Migrating EPAS binaries from ${SRC_BINARY_DIR} to ${BINARY_TOP}"
    sudo cp -a "${SRC_BINARY_DIR}/." "$BINARY_TOP/"

    log_info "Removing duplicate physical EPAS directory: ${SRC_BINARY_DIR}"
    sudo rm -rf "$SRC_BINARY_DIR"
fi

# If BINARY_TOP is empty but the source directory is unavailable,
# fail rather than silently creating an incomplete installation.
if [[ ! -d "$BINARY_TOP/bin" ]]; then
    log_error "EPAS binaries were not found in ${BINARY_TOP}/bin"
    log_error "Expected package binaries at ${SRC_BINARY_DIR} or an existing ${BINARY_TOP}"
    exit 1
fi

# Always expose the standard EDB package path as a symlink.
if [[ ! -e "$SRC_BINARY_DIR" && ! -L "$SRC_BINARY_DIR" ]]; then
    log_info "Creating compatibility symlink: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"
    sudo ln -s "$BINARY_TOP" "$SRC_BINARY_DIR"
elif [[ -L "$SRC_BINARY_DIR" ]]; then
    log_info "Compatibility symlink already configured: ${SRC_BINARY_DIR} -> $(readlink "$SRC_BINARY_DIR")"
else
    log_error "${SRC_BINARY_DIR} still exists as a physical directory; refusing to overwrite it."
    exit 1
fi

# ==========================================
# PERMISSIONS & OWNERSHIP (PLACED BEFORE INITDB)
# ==========================================
# Ownership must be updated before initdb so that the SYSTEM_USER has write access
log_info "Configuring directory ownership to ${SYSTEM_USER}:${SYSTEM_GROUP}"
sudo chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$BINARY_TOP" "$DATA_TOP"
log_info "EPAS binaries: ${BINARY_TOP} (single physical copy)"
log_info "EDB compatibility path: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"

# ==========================================
# SYSTEMD SERVICE CONFIGURATION (DROP-IN)
# ==========================================
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
if [ -f "/usr/lib/systemd/system/${SERVICE_NAME}.service" ]; then
    log_info "Creating Systemd Unit Overrides in ${SYSTEMD_OVERRIDE_DIR}/override.conf"
    sudo mkdir -p "$SYSTEMD_OVERRIDE_DIR"
    
    # Securely write to root-owned systemd folder using sudo tee
    cat << SYS_EOF | sudo tee "${SYSTEMD_OVERRIDE_DIR}/override.conf" > /dev/null
[Service]
User=${SYSTEM_USER}
Group=${SYSTEM_GROUP}
Environment=PGDATA=${DATA_TOP}
PIDFile=${DATA_TOP}/postmaster.pid
SYS_EOF

    sudo systemctl daemon-reload
fi

# ==========================================
# DATABASE CLUSTER INITIALIZATION
# ==========================================
log_info "Initializing Database Cluster with Native TDE Engine"
if [ ! -f "${DATA_TOP}/PG_VERSION" ]; then
    if [[ "${TDE_WRAP_CMD}" == *"CHANGEME"* ]] || [[ "${TDE_UNWRAP_CMD}" == *"CHANGEME"* ]]; then
        log_error "TDE passphrase placeholder detected. Set real passphrase via secrets manager."
        exit 1
    fi
    export PGDATAKEYWRAPCMD="${TDE_WRAP_CMD}"
    export PGDATAKEYUNWRAPCMD="${TDE_UNWRAP_CMD}"

    # Execute initdb switched to the target system user
    sudo -u "$SYSTEM_USER" -E "${BINARY_TOP}/bin/initdb" -D "$DATA_TOP" -E UTF8 --data-encryption=256
fi

sudo mkdir -p "${DATA_TOP}/conf.d"
log_info "Configuring directory ownership to ${SYSTEM_USER}:${SYSTEM_GROUP}"
sudo chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$DATA_TOP"

# ==========================================
# CONFIGURATION INJECTION
# ==========================================
PG_CONF="${DATA_TOP}/postgresql.conf"

# Read PG_CONF securely with sudo to avoid permission denied errors
if ! sudo -u "$SYSTEM_USER" grep -q "include_dir = 'conf.d'" "$PG_CONF"; then
    echo "include_dir = 'conf.d'" | sudo -u "$SYSTEM_USER" tee -a "$PG_CONF" > /dev/null
fi

# Pre-stage Consolidated Performance & Audit Framework Tracking Overlay
log_info "Pre-staging database performance & port parameters to conf.d/"

# Quoting 'EXT_CONF_EOF' prevents Bash from trying to expand $libdir
cat << 'EXT_CONF_EOF' | sudo -u "$SYSTEM_USER" tee "${DATA_TOP}/conf.d/00_custom_perf.conf" > /dev/null

# Connectivity Configuration
port = 5444
listen_addresses='*'

# Consolidated Performance, Compatibility, & Audit Framework Tracking
shared_preload_libraries = '$libdir/dbms_pipe,$libdir/edb_gen,$libdir/dbms_aq,$libdir/sql-profiler,edb_wait_states,edb_stat_monitor,query_advisor,pg_stat_statements,pgaudit,pg_cron,auto_explain'

# ==========================================
# Extension Settings
# ==========================================

edb_wait_states.retention_period = 7776000 #7 Days

# pg_stat_statements
pg_stat_statements.track = all
pg_stat_statements.max = 10000

# pgaudit
pgaudit.log = 'write,ddl'
pgaudit.log_catalog = off

# pg_cron
pg_cron.database_name = 'edb'

# auto_explain
auto_explain.log_min_duration = '5s'
auto_explain.log_analyze = on
auto_explain.log_buffers = on
EXT_CONF_EOF

log_info "Day 1 Base Environment Initialized Successfully."