#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env]
Takes a tagged pgBackRest backup before patching and verifies it.
Settings (config file or environment): STANZA (default: main), BACKUP_TYPE (default: full),
SNAPSHOT_TAG (default: prepatch_<timestamp>); EPAS service from EPAS_VERSION / SERVICE_NAME.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env optional

STANZA="${STANZA:-main}"
BACKUP_TYPE="${BACKUP_TYPE:-full}"
SNAPSHOT_TAG="${SNAPSHOT_TAG:-prepatch_$(date +%F_%H%M%S)}"
show_config EPAS_SERVICE STANZA BACKUP_TYPE SNAPSHOT_TAG

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
    --annotation="host=$(hostname -f 2>/dev/null || hostname)"

log_info "Running post-backup verification"
pgbackrest --stanza="$STANZA" info | tail -20

SNAPSHOT_LOG="/var/log/edb-toolkit/snapshots.log"
# Record the snapshot; a log-permission problem must not fail a backup that already succeeded.
if mkdir -p "$(dirname "$SNAPSHOT_LOG")" 2>/dev/null && \
   echo "$(date '+%F %T') | ${SNAPSHOT_TAG} | ${STANZA} | ${BACKUP_TYPE} | $(hostname -f 2>/dev/null || hostname) | $(whoami)" >> "$SNAPSHOT_LOG" 2>/dev/null; then
    :
else
    log_warn "Backup succeeded, but could not write ${SNAPSHOT_LOG} (check permissions)."
fi

log_audit "Pre-patch snapshot completed: ${SNAPSHOT_TAG}"
echo ""
echo "Snapshot Summary:"
echo "  Tag:        ${SNAPSHOT_TAG}"
echo "  Stanza:     ${STANZA}"
echo "  Type:       ${BACKUP_TYPE}"
echo "  Log:        ${SNAPSHOT_LOG}"
