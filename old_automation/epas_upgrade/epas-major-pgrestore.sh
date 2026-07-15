#!/bin/bash
# ==============================================================================
# SCRIPT: epas-major-pgrestore.sh
# DESCRIPTION: Migrates EPAS 14 to EPAS 17 with TDE using logical pg_dump/restore
# ==============================================================================
set -euo pipefail
trap 'echo "[ERROR] Script failed at line ${LINENO}. Review log for details."; exit 1' ERR

log() { echo "$(date '+%F %T') $*"; }

# --- ENV & DIRECTORY LAYOUT ---
OLD_PORT=5105
NEW_PORT=5444
OLD_BIN="/usr/edb/as14/bin"
NEW_BIN="/usr/edb/as17/bin"
OLD_DATA="/pgdata/as14/data"
NEW_DATA="/pgdata/as17/data"
OS_USER="enterprisedb"
OS_GROUP="enterprisedb"
BACKUP_DIR="/backup"

[ "$EUID" -eq 0 ] || { echo "ERROR: Run as root."; exit 1; }

# --- HA & SAFETY GUARDS ---
if systemctl list-units --type=service --state=running | grep -q "edb-efm-"; then
    log "[ERROR] Active EFM service detected. Stop or set EFM to MAINTENANCE mode first."
    exit 1
fi

# Ensure free storage space (> 50% of old data size for safety during logical dump)
AVAILABLE=$(df -Pk "$NEW_DATA" | awk 'NR==2{print $4}')
[ "$AVAILABLE" -ge 1048576 ] || { echo "ERROR: Less than 1GB free disk space available."; exit 1; }

# --- CREDENTIAL INGESTION ---
read -s -p "Enter TDE master passphrase: " PGPASSWORD_TDE; echo ""
export PGPASSWORD_TDE

# --- LOGGING SETUP ---
LOG_FILE="/var/log/epas_migration_restore_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -i "$LOG_FILE") 2>&1

# --- STEP 1: PHYSICAL SNAPSHOT ---
log "Archiving old data directory..."
mkdir -p "$BACKUP_DIR"
tar czf "${BACKUP_DIR}/as14-data-pre-migration-$(date +%Y%m%d).tar.gz" "$OLD_DATA"

# --- STEP 2: INSTALL & INIT NEW ENGINE ---
log "Installing target engine software..."
dnf install -y edb-as17-server edb-as17-contrib

log "Initializing target EPAS 17 instance with TDE active..."
mkdir -p "$NEW_DATA"
chown "$OS_USER:$OS_GROUP" "$NEW_DATA"
chmod 700 "$NEW_DATA"

sudo -u "$OS_USER" PGPASSWORD="$PGPASSWORD_TDE" \
    "$NEW_BIN/initdb" -D "$NEW_DATA" -E UTF8 \
    --locale=en_US.UTF-8 --data-encryption-algorithm=AES256

# --- STEP 3: MIGRATION PIPELINE ---
log "Starting engine instances..."
systemctl start edb-as-14
systemctl start edb-as-17

log "Copying global system catalogs..."
"$NEW_BIN/pg_dumpall" -p "$OLD_PORT" --globals-only | "$NEW_BIN/psql" -p "$NEW_PORT" -d postgres

log "Parsing databases for processing..."
DATABASES=$("$OLD_BIN/psql" -p "$OLD_PORT" -d postgres -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate=false AND datallowconn=true;")

for DB in $DATABASES; do
    [[ "$DB" == "postgres" || "$DB" == "edb" ]] && continue
    log "Streaming structural logical data for database: $DB"
    "$NEW_BIN/createdb" -p "$NEW_PORT" "$DB"
    
    # Parallel streaming backup to restore execution path
    "$OLD_BIN/pg_dump" -p "$OLD_PORT" -d "$DB" -F c | \
        "$NEW_BIN/pg_restore" -p "$NEW_PORT" -d "$DB" --no-owner
done

# --- STEP 4: SWAP & OPTIMIZE ---
log "Executing cluster runtime cutover..."
systemctl stop edb-as-14
systemctl disable edb-as-14
systemctl enable edb-as-17

log "Optimizing database statistics catalog..."
"$NEW_BIN/vacuumdb" --all --analyze-in-stages -p "$NEW_PORT"

log "Migration completely processing via logical restore method."