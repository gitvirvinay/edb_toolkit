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

# CRITICAL: pg_upgrade with --link demands identical TDE keys across structures.
read -s -p "Enter TDE master passphrase: " PGPASSWORD_TDE; echo ""

read -p "Have you taken a verified filesystem-level backup of ${OLD_DATA}? (yes/NO): " BACKUP_CONFIRM
[[ "$BACKUP_CONFIRM" == "yes" ]] || { log_error "Aborting -- verified backup required before --link migration."; exit 1; }

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

log_info "Executing structural compatibility preflight analysis..."
sudo -u "$OS_USER" PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" \
    --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
    --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
    --link --check

read -p "Preflight passed. Trigger metadata link migration? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

sudo -u "$OS_USER" PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" \
    --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
    --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
    --link

if [ -f "./analyze_new_cluster.sh" ]; then
    log_info "Rebuilding database statistics optimization tables..."
    sudo -u "$OS_USER" bash ./analyze_new_cluster.sh
fi

log_audit "Major upgrade completed: ${OLD_DATA} -> ${NEW_DATA}"
