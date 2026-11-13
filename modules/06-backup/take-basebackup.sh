#!/usr/bin/env bash
# =============================================================================
# modules/06-backup/take-basebackup.sh - pg_basebackup into BACKUP_TOP, then prune old ones
#
#   sudo -iu enterprisedb modules/06-backup/take-basebackup.sh [--env conf/site.env] [--yes] [tag]
#
# Only acts when BACKUP_TOOL=basebackup (refuses otherwise - run the matching script for
# whatever BACKUP_TOOL is actually set, e.g. pgbackrest-validate.sh / your pgBackRest backup).
#
# Run as SYSTEM_USER (the database OS user): pg_basebackup connects over the local Unix
# socket, which initdb's default pg_hba.conf allows for that user via peer authentication -
# no replication password needed for a local backup.
#
# Steps: EPAS must be up -> enough free space on BACKUP_TOP (checked against DATA_TOP's
# current size, with headroom) -> pg_basebackup into a new, timestamped directory -> on
# success, prune backups under BACKUP_TOP older than BACKUP_RETENTION_DAYS (default 10).
# Pruning only ever happens after a new backup has succeeded, so a failed run never leaves
# zero backups on disk. Meant to run from cron (pass --yes - see "Scheduling" below).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes] [tag]
Takes a pg_basebackup into BACKUP_TOP/<timestamp>_<tag> (tag default: scheduled), then
prunes backups under BACKUP_TOP older than BACKUP_RETENTION_DAYS (default 10) - only after
the new backup succeeds. Only runs when BACKUP_TOOL=basebackup. Run as SYSTEM_USER.

Scheduling (cron, as SYSTEM_USER): --yes is required - pruning is a destructive step, and
with no terminal (which cron has none of) it is refused without it, same as any other
irreversible action in this toolkit.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; esac
load_env optional

case "$(_lower "${BACKUP_TOOL:-basebackup}")" in
    basebackup) ;;
    *) die "BACKUP_TOOL=${BACKUP_TOOL} - this script only runs backups for BACKUP_TOOL=basebackup. Use the script for your actual BACKUP_TOOL instead." ;;
esac

require_vars DATA_TOP BACKUP_TOP SYSTEM_USER BINARY_TOP PRIMARY_PORT
[ "$(whoami)" = "$SYSTEM_USER" ] || die "Run this as ${SYSTEM_USER} (sudo -iu ${SYSTEM_USER} ...): pg_basebackup authenticates locally as that OS user."

EPAS_SVC="${EPAS_SERVICE:-${SERVICE_NAME:-}}"
systemctl is-active --quiet "$EPAS_SVC" || die "${EPAS_SVC} is not running. A base backup needs a running, consistent cluster."

TAG="${1:-scheduled}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-10}"
DEST="${BACKUP_TOP}/$(date +%F_%H%M%S)_${TAG}"
show_config DATA_TOP BACKUP_TOP RETENTION_DAYS PRIMARY_PORT

mkdir -p "$BACKUP_TOP"

# --- Free space check: BACKUP_TOP needs at least the current data size, plus headroom ----------
DATA_BYTES=$(du -sb "$DATA_TOP" 2>/dev/null | cut -f1 || echo 0)
AVAIL_BYTES=$(df --output=avail -B1 "$BACKUP_TOP" 2>/dev/null | tail -1)
NEEDED_BYTES=$(( DATA_BYTES + DATA_BYTES / 10 ))      # +10% headroom (WAL churn during the copy)
if [ -n "${AVAIL_BYTES:-}" ] && [ "$AVAIL_BYTES" -lt "$NEEDED_BYTES" ]; then
    die "Not enough space on ${BACKUP_TOP}: ${AVAIL_BYTES} bytes free, need about ${NEEDED_BYTES} (data is ${DATA_BYTES} bytes). Backup not started."
fi

log_info "Starting pg_basebackup: ${DATA_TOP} -> ${DEST}"
"${BINARY_TOP}/bin/pg_basebackup" \
    -D "$DEST" \
    -p "$PRIMARY_PORT" \
    --format=plain \
    --wal-method=stream \
    --checkpoint=fast \
    --progress \
    --no-password \
    2>&1 | while IFS= read -r line; do log_debug "pg_basebackup: $line"; done

[ -f "${DEST}/backup_label" ] || die "pg_basebackup did not leave a backup_label in ${DEST} - treating this backup as failed. Existing backups were not touched."

BACKUP_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
log_info "Base backup completed: ${DEST} (${BACKUP_SIZE})"
log_audit "Base backup taken: ${DEST} (${BACKUP_SIZE})"

# --- Retention: prune OUR OWN backup directories under BACKUP_TOP older than RETENTION_DAYS ----
# Matched by name (YYYY-MM-DD_HHMMSS_tag), so a directory that was not made by this script,
# or the one just taken, is never touched.
mapfile -t OLD < <(find "$BACKUP_TOP" -maxdepth 1 -mindepth 1 -type d \
                        -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*' \
                        -mtime "+${RETENTION_DAYS}" 2>/dev/null | sort)
if [ "${#OLD[@]}" -eq 0 ]; then
    log_info "Retention: nothing older than ${RETENTION_DAYS} days to prune."
else
    log_info "Retention: ${#OLD[@]} backup(s) older than ${RETENTION_DAYS} days:"
    for d in "${OLD[@]}"; do log_info "  $d"; done
    confirm_destructive "delete the ${#OLD[@]} backup(s) listed above under ${BACKUP_TOP}"
    for d in "${OLD[@]}"; do
        rm -rf "$d"
        log_audit "Pruned old base backup: $d"
    done
fi
