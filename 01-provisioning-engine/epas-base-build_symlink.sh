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
[[ "$EPAS_VERSION" =~ ^[0-9]+$ ]] || { log_error "EPAS_VERSION must be numeric"; exit 1; }
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Invalid SERVICE_NAME"; exit 1; }

: "${SYSTEM_USER:?SYSTEM_USER variable is unset}"
: "${SYSTEM_GROUP:?SYSTEM_GROUP variable is unset}"
: "${PRIMARY_PORT:?PRIMARY_PORT variable is unset}"

log_info "START: EPAS ${EPAS_VERSION} Enterprise Build Infrastructure"
PACKAGE_NAME="edb-as${EPAS_VERSION}-server"

#==========================================
# PACKAGE INSTALLATION (RESILIENT LOOP)
# ==========================================
# NOTE: pgaudit / pg_cron are referenced in conf.d/04-extensions.conf.
#       Uncomment the matching lines below (or install separately) BEFORE the
#       first cluster start, or the server will fail to boot.
# ==========================================
PACKAGES=(
    "$PACKAGE_NAME"
    "${PACKAGE_NAME}-edb_wait_states"
    "edb-as${EPAS_VERSION}-query-advisor*"
    "edb-as${EPAS_VERSION}-stat_monitor*"
    #"edb-pg${EPAS_VERSION}-pgaudit*"
    #"edb-pg${EPAS_VERSION}-pg-cron*"
    #"pg_repack"
    "edb-lasso"
    "edb-pwr"
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
log_info "Configuring EPAS binary location: ${BINARY_TOP}"
log_info "Compatibility path: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"

sudo mkdir -p "$DATA_TOP"

if [[ -L "$SRC_BINARY_DIR" ]]; then
    CURRENT_TARGET="$(readlink -f "$SRC_BINARY_DIR" 2>/dev/null || true)"
    EXPECTED_TARGET="$(readlink -f "$BINARY_TOP" 2>/dev/null || true)"
    if [[ "$CURRENT_TARGET" == "$EXPECTED_TARGET" && -d "$BINARY_TOP/bin" ]]; then
        log_info "${SRC_BINARY_DIR} already points to ${BINARY_TOP}; no binary copy required."
    else
        log_warn "${SRC_BINARY_DIR} is a symlink but does not point to ${BINARY_TOP}. Replacing."
        sudo rm -f "$SRC_BINARY_DIR"
    fi
fi

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

if [[ ! -d "$BINARY_TOP/bin" ]]; then
    log_error "EPAS binaries were not found in ${BINARY_TOP}/bin"
    exit 1
fi

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
# PERMISSIONS & OWNERSHIP (BEFORE INITDB)
# ==========================================
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
    sudo -u "$SYSTEM_USER" -E "${BINARY_TOP}/bin/initdb" -D "$DATA_TOP" -E UTF8 --data-encryption=256
fi

sudo mkdir -p "${DATA_TOP}/conf.d"
sudo chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$DATA_TOP"

# ==========================================
# CONFIGURATION INJECTION
# ==========================================
PG_CONF="${DATA_TOP}/postgresql.conf"
if ! sudo -u "$SYSTEM_USER" grep -q "include_dir = 'conf.d'" "$PG_CONF"; then
    echo "include_dir = 'conf.d'" | sudo -u "$SYSTEM_USER" tee -a "$PG_CONF" > /dev/null
fi

# -----------------------------------------------------------------------------
# CONF.D TEMPLATE STAGING
#
# Templates are dropped into conf.d/ ONLY if absent - local/site edits are
# never overwritten on re-run. conf.d files load in C-string sort order, so
# numbering controls precedence:
#
#   01-network.conf       connectivity / port / max_connections
#   02-memory.conf        memory sizing (auto-tuned to host RAM at build time)
#   03-logging.conf       logging collector & rotation
#   04-extensions.conf    shared_preload_libraries + per-extension settings
#   05-compatibility.conf EPAS/Oracle compatibility switches
#   99-local.conf         LAST template slot for site-specific overrides
#
# (epas-ssl-setup.sh later adds 'ssl.conf'; alphabetically 'ssl.conf' sorts
#  AFTER '99-local.conf', so SSL knobs always win.)
# -----------------------------------------------------------------------------

TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
SHARED_BUFFERS_MB=$(( TOTAL_MEM_KB / 4 / 1024 ))              # 25% of RAM
EFFECTIVE_CACHE_MB=$(( TOTAL_MEM_KB * 3 / 4 / 1024 ))         # 75% of RAM
MAINT_WORK_MEM_MB=$(( TOTAL_MEM_KB / 16 / 1024 ))
[[ $MAINT_WORK_MEM_MB -gt 2048 ]] && MAINT_WORK_MEM_MB=2048   # cap 2GB
WORK_MEM_MB=$(( TOTAL_MEM_KB / 1024 / 400 ))
[[ $WORK_MEM_MB -lt 4 ]] && WORK_MEM_MB=4
[[ $WORK_MEM_MB -gt 64 ]] && WORK_MEM_MB=64

log_info "Pre-staging conf.d templates (shared_buffers=${SHARED_BUFFERS_MB}MB, effective_cache=${EFFECTIVE_CACHE_MB}MB)"

# stage_template <filename> : reads template content from STDIN.
# Never overwrites an existing file in conf.d.
stage_template() {
    local target="${DATA_TOP}/conf.d/$1"
    if [[ -f "$target" ]]; then
        log_info "conf.d/$1 already exists - keeping local version"
    else
        sudo -u "$SYSTEM_USER" tee "$target" > /dev/null
        log_info "Staged conf.d/$1"
    fi
}

# ---- 01-network.conf ---------------------------------------------------------
stage_template "01-network.conf" <<EOF
# Connectivity & network sizing
# Managed by epas-base-build - edit freely; never overwritten on re-run.
port = ${PRIMARY_PORT}
listen_addresses = '*'
max_connections = 300
superuser_reserved_connections = 10
tcp_keepalives_idle = 600
tcp_keepalives_interval = 30
tcp_keepalives_count = 3
EOF

# ---- 02-memory.conf ----------------------------------------------------------
stage_template "02-memory.conf" <<EOF
# Memory sizing - auto-tuned at build time ($(date +%F)) for ${TOTAL_MEM_KB} kB RAM
# Managed by epas-base-build - edit freely; never overwritten on re-run.
shared_buffers = ${SHARED_BUFFERS_MB}MB
huge_pages = try
effective_cache_size = ${EFFECTIVE_CACHE_MB}MB
maintenance_work_mem = ${MAINT_WORK_MEM_MB}MB
work_mem = ${WORK_MEM_MB}MB
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
random_page_cost = 1.1
EOF

# ---- 03-logging.conf ---------------------------------------------------------
stage_template "03-logging.conf" <<EOF
# Logging collector, rotation & statement logging
# Managed by epas-base-build - edit freely; never overwritten on re-run.
logging_collector = on
log_destination = 'stderr'
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_rotation_size = 0
log_min_duration_statement = 1000
log_statement = 'ddl'
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_autovacuum_min_duration = 0
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'UTC'
EOF

# ---- 04-extensions.conf ------------------------------------------------------
# Heredoc is QUOTED so \$libdir survives; ${EPAS_VERSION} is expanded via an
# unquoted inner substitution where needed.
stage_template "04-extensions.conf" <<EOF
# Extension framework: preload list + per-extension settings
# Managed by epas-base-build - edit freely; never overwritten on re-run.
# WARNING: every module in shared_preload_libraries MUST be installed
#          or the server will refuse to start (see pgaudit / pg_cron notes).

shared_preload_libraries = '\$libdir/dbms_pipe,\$libdir/edb_gen,\$libdir/dbms_aq,\$libdir/sql-profiler,\$libdir/edb_filter_log,edb_wait_states,edb_stat_monitor,query_advisor,pg_stat_statements,auto_explain'

# edb_wait_states
edb_wait_states.retention_period = 7776000   # 90 days

# pg_stat_statements
pg_stat_statements.track = all
pg_stat_statements.max = 10000

# pgaudit (requires edb-pg${EPAS_VERSION}-pgaudit package)
pgaudit.log = 'write,ddl'
pgaudit.log_catalog = off

# pg_cron (requires edb-pg${EPAS_VERSION}-pg-cron package)
pg_cron.database_name = 'edb'

# auto_explain
auto_explain.log_min_duration = '5s'
auto_explain.log_analyze = on
auto_explain.log_buffers = on
EOF

# ---- 05-compatibility.conf ---------------------------------------------------
stage_template "05-compatibility.conf" <<'EOF'
# EPAS / Oracle-mode compatibility switches
# Managed by epas-base-build - edit freely; never overwritten on re-run.
edb_redwood_strings = on
edb_redwood_date = on
edb_redwood_greatest_least = on
edb_dynatune = on
edb_dynatune_profile = oltp
search_path = '"$user", public, sys, dbo'
standard_conforming_strings = on
EOF

# ---- 99-local.conf -----------------------------------------------------------
stage_template "99-local.conf" <<'EOF'
# 99-local.conf - site-specific overrides (loaded after all numbered templates)
# Managed by epas-base-build - edit freely; never overwritten on re-run.
# Put anything that must override the numbered templates here, e.g.:
#   shared_buffers = 64GB
#   log_min_duration_statement = 500
EOF

log_info "Day 1 Base Environment Initialized Successfully."
