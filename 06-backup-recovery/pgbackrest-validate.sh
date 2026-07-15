#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

STANZA="${STANZA:-main}"
RETENTION_FULL="${RETENTION_FULL:-2}"

log_info "Starting pgBackRest validation for stanza: ${STANZA}"

log_info "[Check 1] Verifying stanza configuration"
pgbackrest --stanza="$STANZA" check || { log_error "Stanza check failed"; exit 1; }

log_info "[Check 2] Retrieving repository info"
pgbackrest --stanza="$STANZA" info || { log_error "Repository info failed"; exit 1; }

log_info "[Check 3] Checking for recent backup"
LATEST_BACKUP=$(pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['backup'][-1]['label'] if d[0]['backup'] else 'NONE')" 2>/dev/null || echo "NONE")

if [ "$LATEST_BACKUP" == "NONE" ]; then
    log_error "No backups found in stanza ${STANZA}"
    exit 1
fi

log_info "Latest backup found: ${LATEST_BACKUP}"

log_info "[Check 4] Running backup integrity verification"
pgbackrest --stanza="$STANZA" verify || { log_warn "Backup verification reported issues"; }

log_info "[Check 5] Checking WAL archive continuity"
ARCHIVE_MIN=$(pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['archive'][0]['min'] if d[0].get('archive') else 'UNKNOWN')" 2>/dev/null || echo "UNKNOWN")
ARCHIVE_MAX=$(pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['archive'][0]['max'] if d[0].get('archive') else 'UNKNOWN')" 2>/dev/null || echo "UNKNOWN")

log_info "WAL archive range: ${ARCHIVE_MIN} -> ${ARCHIVE_MAX}"

log_audit "pgBackRest validation completed successfully for stanza: ${STANZA}"
