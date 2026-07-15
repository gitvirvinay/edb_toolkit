#!/bin/bash
# ==============================================================================
# SCRIPT: epas-major-pgupgrade.sh
# DESCRIPTION: Direct upgrade using pg_upgrade --copy-by-block for TDE transformation
# ==============================================================================
set -euo pipefail
trap 'echo "[ERROR] Script failed at line ${LINENO}. Review log for details."; exit 1' ERR

log() { echo "$(date '+%F %T') $*"; }

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

if systemctl list-units --type=service --state=running | grep -q "edb-efm-"; then
    log "[ERROR] Active EFM cluster framework detected. Put EFM into maintenance before patching."
    exit 1
fi

read -s -p "Enter TDE master passphrase: " PGPASSWORD_TDE; echo ""

export PGDATAKEYWRAPCMD="openssl enc -e -aes-128-cbc -pbkdf2 -pass pass:$PGPASSWORD_TDE -out \"%p\""
export PGDATAKEYUNWRAPCMD="openssl enc -d -aes-128-cbc -pbkdf2 -pass pass:$PGPASSWORD_TDE -in \"%p\""

LOG_FILE="/var/log/epas_migration_upgrade_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -i "$LOG_FILE") 2>&1

log "Creating snapshot backup..."
mkdir -p "$BACKUP_DIR"
tar czf "${BACKUP_DIR}/as14-data-$(date +%Y%m%d_%H%M%S).tar.gz" "$OLD_DATA"

log "Installing EPAS 17 runtime packages..."
dnf install -y edb-as17-server edb-as17-contrib

log "Initializing target engine cluster data directories with TDE parameters..."
mkdir -p "$NEW_DATA"
chown "$OS_USER:$OS_GROUP" "$NEW_DATA"
chmod 700 "$NEW_DATA"

sudo -u "$OS_USER" PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/initdb" -D "$NEW_DATA" -E UTF8 \
    --locale=en_US.UTF-8 --data-encryption-algorithm=AES256

log "Ensuring engine services are cleanly stopped for upgrade migration..."
systemctl stop edb-as-14 || true
systemctl stop edb-as-17 || true

log "Running pg_upgrade validation pre-flight check..."
cd "$NEW_DATA"
sudo -u "$OS_USER" PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" \
    --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
    --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
    --old-port="$OLD_PORT" --new-port="$NEW_PORT" \
    --copy-by-block --check

echo "----------------------------------------------------------------"
read -p "Pre-flight validation checks complete. Proceed with live binary copy conversion? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Upgrade execution aborted by user choice."; exit 0; }

log "Executing live block upgrade with on-the-fly encryption updates..."
sudo -u "$OS_USER" PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" \
    --old-datadir="$OLD_DATA" --new-datadir="$NEW_DATA" \
    --old-bindir="$OLD_BIN" --new-bindir="$NEW_BIN" \
    --old-port="$OLD_PORT" --new-port="$NEW_PORT" \
    --copy-by-block

log "Writing persistent TDE variables to systemd unit override profiles..."
mkdir -p /etc/systemd/system/edb-as-17.service.d
cat <<EOF > /etc/systemd/system/edb-as-17.service.d/tde.conf
[Service]
Environment="PGDATAKEYWRAPCMD=$PGDATAKEYWRAPCMD"
Environment="PGDATAKEYUNWRAPCMD=$PGDATAKEYUNWRAPCMD"
EOF

systemctl daemon-reload
systemctl disable edb-as-14
systemctl enable edb-as-17
systemctl start edb-as-17

log "Running parallel system optimization vacuum procedures..."
sudo -u "$OS_USER" "$NEW_BIN/vacuumdb" --all --analyze-in-stages -p "$NEW_PORT"

log "EPAS 14 directly converted to EPAS 17 with active TDE layers completely."