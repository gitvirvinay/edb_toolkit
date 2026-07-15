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

# Validate critical variables
[[ "$EPAS_VERSION" =~ ^[0-9]+$ ]] || { log_error "EPAS_VERSION must be numeric"; exit 1; }
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { log_error "Invalid SERVICE_NAME"; exit 1; }

log_info "START: EPAS ${EPAS_VERSION} Enterprise Build Infrastructure"
PACKAGE_NAME="edb-as${EPAS_VERSION}-server"

if ! dnf list installed "$PACKAGE_NAME" &>/dev/null; then
    log_info "Installing $PACKAGE_NAME and extension packages via DNF"
    dnf install -y "$PACKAGE_NAME" edb-pwr edb-lasso "pgaudit${EPAS_VERSION}" "pg_repack${EPAS_VERSION}" "pg_cron${EPAS_VERSION}"
fi

mkdir -p "$BINARY_TOP" "$DATA_TOP" "${DATA_TOP}/conf.d"
if [ -d "$SRC_BINARY_DIR" ]; then
    if [ -d "$BINARY_TOP/bin" ]; then
        BACKUP_BIN="${BINARY_TOP}_bak_$(date +%F_%H%M%S)"
        log_warn "Existing binaries found. Rotating to ${BACKUP_BIN}"
        mv "$BINARY_TOP" "$BACKUP_BIN"
        mkdir -p "$BINARY_TOP"
    fi
    cp -r "${SRC_BINARY_DIR}/." "$BINARY_TOP/"
fi

TARGET_SERVICE="/usr/lib/systemd/system/${SERVICE_NAME}.service"
if [ -f "$TARGET_SERVICE" ]; then
    log_info "Customizing Systemd Unit Overrides"
    sed -i "s|^Environment=PGDATA=.*|Environment=PGDATA=${DATA_TOP}|" "$TARGET_SERVICE"
    sed -i "s|^ExecStart=.*|ExecStart=${BINARY_TOP}/bin/pg_ctl start -D \${PGDATA} -s -w -t 300|" "$TARGET_SERVICE"
fi

log_info "Initializing Database Cluster with Native TDE Engine"
if [ ! -f "${DATA_TOP}/PG_VERSION" ]; then
    if [[ "${TDE_WRAP_CMD}" == *"CHANGEME"* ]] || [[ "${TDE_UNWRAP_CMD}" == *"CHANGEME"* ]]; then
        log_error "TDE passphrase placeholder detected. Set real passphrase via secrets manager."
        exit 1
    fi
    export PGDATAKEYWRAPCMD="${TDE_WRAP_CMD}"
    export PGDATAKEYUNWRAPCMD="${TDE_UNWRAP_CMD}"

    sudo -u "$SYSTEM_USER" -E "${BINARY_TOP}/bin/initdb" -D "$DATA_TOP" -E UTF8 --data-encryption-algorithm=AES256
fi

PG_CONF="${DATA_TOP}/postgresql.conf"
if ! grep -q "include_dir = 'conf.d'" "$PG_CONF"; then
    cat << CONF_EOF >> "$PG_CONF"
include_dir = 'conf.d'
port = ${PRIMARY_PORT}
CONF_EOF
fi

# Pre-stage Consolidated Performance & Audit Framework Tracking Overlay
log_info "Pre-staging database performance extension parameters to conf.d/"
cat << EXT_CONF_EOF > "${DATA_TOP}/conf.d/00_perf_extensions.conf"
# Consolidated Performance & Audit Framework Tracking
shared_preload_libraries = 'edb_wait_states, pg_stat_statements, pgaudit, pg_cron, auto_explain'

edb_wait_states.enable = on
edb_wait_states.retention_period = 300
edb_wait_states.history_duration = 7
EXT_CONF_EOF

chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$BINARY_TOP" "$DATA_TOP"
log_info "Day 1 Base Environment Initialized Successfully."
