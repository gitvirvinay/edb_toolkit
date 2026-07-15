#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

STANZA="${STANZA:-main}"
BACKUP_TYPE="${BACKUP_TYPE:-full}"
EPAS_SERVICE="${EPAS_SERVICE:-edb-as-17}"
SNAPSHOT_TAG="${SNAPSHOT_TAG:-prepatch_$(date +%F_%H%M%S)}"

log_info "Starting pre-patch snapshot: ${SNAPSHOT_TAG}"

if ! sudo systemctl is-active --quiet "$EPAS_SERVICE"; then
    log_error "EPAS service ${EPAS_SERVICE} is not running. Cannot take consistent backup."
    exit 1
fi

log_info "Validating pgBackRest stanza before backup"
pgbackrest --stanza="$STANZA" check || { log_error "Stanza validation failed"; exit 1; }

log_info "Executing ${BACKUP_TYPE} backup with tag: ${SNAPSHOT_TAG}"
pgbackrest --stanza="$STANZA" --type="$BACKUP_TYPE" backup \
    --annotation="source=${SNAPSHOT_TAG}" \
    --annotation="initiated_by=$(whoami)" \
    --annotation="host=$(hostname -f)"

log_info "Running post-backup verification"
pgbackrest --stanza="$STANZA" info | tail -20

SNAPSHOT_LOG="/var/log/edb-toolkit/snapshots.log"
mkdir -p "$(dirname "$SNAPSHOT_LOG")"
echo "$(date '+%F %T') | ${SNAPSHOT_TAG} | ${STANZA} | ${BACKUP_TYPE} | $(hostname -f) | $(whoami)" >> "$SNAPSHOT_LOG"

log_audit "Pre-patch snapshot completed: ${SNAPSHOT_TAG}"
echo ""
echo "Snapshot Summary:"
echo "  Tag:        ${SNAPSHOT_TAG}"
echo "  Stanza:     ${STANZA}"
echo "  Type:       ${BACKUP_TYPE}"
echo "  Log:        ${SNAPSHOT_LOG}"
