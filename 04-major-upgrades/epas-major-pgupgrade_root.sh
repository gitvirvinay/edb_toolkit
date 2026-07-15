#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

OLD_BIN="/usr/edb/as14/bin"
NEW_BIN="/usr/edb/as17/bin"
OLD_DATA="/pgdata/as14/data"
NEW_DATA="/pgdata/as17/data"
OS_USER="enterprisedb"

[ "$EUID" -eq 0 ] || { log_error "Run as root."; exit 1; }

# --- DISK SPACE CHECK ---
# Upgrading without --link copies data. Ensure the target partition has enough space.
log_info "Verifying disk space allocation..."
OLD_DATA_SIZE_KB=$(du -s "$OLD_DATA" | awk '{print $1}')
NEW_DATA_DIR=$(dirname "$NEW_DATA")
FREE_SPACE_KB=$(df -k "$NEW_DATA_DIR" | awk 'NR==2 {print $4}')

# Allow a 10% buffer for safety
REQUIRED_SPACE_KB=$(( OLD_DATA_SIZE_KB + (OLD_DATA_SIZE_KB / 10) ))

if [ "$FREE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
    log_error "Insufficient disk space on ${NEW_DATA_DIR}."
    log_error "Required: ~$(( REQUIRED_SPACE_KB / 1024 )) MB | Free: $(( FREE_SPACE_KB / 1024 )) MB"
    log_error "Aborting: Copy-based upgrade requires enough space for both clusters."
    exit 1
fi

# --- SECURITY / TDE PASSPHRASE PREPARATION ---
read -s -p "Enter TDE master passphrase: " PGPASSWORD_TDE; echo ""

read -p "Have you taken a verified filesystem-level backup of ${OLD_DATA}? (yes/NO): " BACKUP_CONFIRM
[[ "$BACKUP_CONFIRM" == "yes" ]] || { log_error "Aborting -- verified backup highly recommended before major migration."; exit 1; }

TMP_PASS=$(mktemp)
chmod 600 "$TMP_PASS"
printf '%s' "$PGPASSWORD_TDE" > "$TMP_PASS"

export PGDATAKEYWRAPCMD="openssl enc -e -aes-128-cbc -pbkdf2 -pass file:${TMP_PASS} -out %p"
export PGDATAKEYUNWRAPCMD="openssl enc -d -aes-128-cbc -pbkdf2 -pass file:${TMP_PASS} -in %p"

cleanup() {
    if [ -f "$TMP_PASS" ]; then
        shred -u "$TMP_PASS" 2>/dev/null || rm -f "$TMP_PASS"
    fi
}
trap cleanup EXIT INT TERM HUP

# Shift context into universally writable location to avoid pg_upgrade log crash
cd /tmp

# --- PREFLIGHT RUN (CHECK MODE) ---
log_info "Executing structural compatibility preflight analysis (No-Link Copy Mode)..."
sudo -u "$OS_USER" PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" \
    --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
    --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
    --check

read -p "Preflight passed. Trigger COPY-based database migration? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

# --- ACTUAL RUN (COPY MODE) ---
log_info "Starting database file copy upgrade... (This may take a while depending on DB size)"
sudo -u "$OS_USER" PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" \
    --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
    --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN"

if [ -f "./analyze_new_cluster.sh" ]; then
    log_info "Rebuilding database statistics optimization tables..."
    sudo -u "$OS_USER" bash ./analyze_new_cluster.sh
fi

log_audit "Major upgrade completed (Copy-mode): ${OLD_DATA} -> ${NEW_DATA}"
log_info "Note: The old cluster data remains in ${OLD_DATA}. You can manually delete it once validated."