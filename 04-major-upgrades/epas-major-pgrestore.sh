#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

OLD_PORT=5105
NEW_PORT=5444
OLD_BIN="/usr/edb/as14/bin"
NEW_BIN="/usr/edb/as17/bin"
OLD_DATA="/pgdata/as14/data"
NEW_DATA="/pgdata/as17/data"
OS_USER="enterprisedb"

[ "$EUID" -eq 0 ] || { log_error "Run as root."; exit 1; }

read -s -p "Enter Target TDE Initialization Passphrase: " PGPASSWORD_TDE; echo ""
mkdir -p "$NEW_DATA"
chown "${OS_USER}:${OS_USER}" "$NEW_DATA"
chmod 700 "$NEW_DATA"

# Allocate structural extensions overlay direct to target path
mkdir -p "${NEW_DATA}/conf.d"
cat << EXT_CONF_EOF > "${NEW_DATA}/conf.d/00_perf_extensions.conf"
shared_preload_libraries = 'edb_wait_states, pg_stat_statements, pgaudit, pg_cron, auto_explain'
edb_wait_states.enable = on
edb_wait_states.retention_period = 300
edb_wait_states.history_duration = 7
EXT_CONF_EOF

sudo -u "$OS_USER" PGPASSWORD="$PGPASSWORD_TDE" \
    "$NEW_BIN/initdb" -D "$NEW_DATA" -E UTF8 --locale=en_US.UTF-8 --data-encryption-algorithm=AES256

log_info "Streaming global definitions across engine endpoints..."
"$NEW_BIN/pg_dumpall" -p "$OLD_PORT" --globals-only | "$NEW_BIN/psql" -p "$NEW_PORT" -d postgres

DATABASES=$("$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datallowconn=true;")
for DB in $DATABASES; do
    [[ "$DB" == "postgres" || "$DB" == "edb" ]] && continue
    log_info "Processing parallel streaming migration path for: $DB (Ensure /tmp has adequate capacity)"
    "$NEW_BIN/createdb" -p "$NEW_PORT" "$DB"
    DUMP_FILE="/tmp/${DB}_$(date +%s).dump"
    "$OLD_BIN/pg_dump" -p "$OLD_PORT" -Fc "$DB" > "$DUMP_FILE"
    "$NEW_BIN/pg_restore" -p "$NEW_PORT" -d "$DB" -j 4 "$DUMP_FILE"
    rm -f "$DUMP_FILE"
done

log_audit "Logical restore migration completed successfully"
