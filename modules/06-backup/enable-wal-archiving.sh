#!/usr/bin/env bash
# =============================================================================
# modules/06-backup/enable-wal-archiving.sh - turn on WAL archiving (BACKUP_TOOL=basebackup)
#
#   modules/06-backup/enable-wal-archiving.sh [--env conf/site.env]
#
# Stages conf.d/06-archiving.conf (archive_mode=on, archive_command -> archive-wal.sh), the
# same way epas-base-build-db.sh stages 01-network.conf etc: only if that file is not already
# there, so running this again, or on a server someone else already set up, changes nothing.
#
# Called automatically by epas-base-build-db.sh for a brand-new cluster (before first start,
# so archiving is on from the very first WAL file - no restart needed). Also safe to run by
# hand against an existing, grandfathered cluster - but archive_mode only takes effect on a
# RESTART (it is read once at startup, unlike most settings reload picks up). This script
# never restarts EPAS itself; if the service is already running it tells you to schedule one
# with modules/03-patching/node-maintenance-stop.sh / node-maintenance-start.sh.
#
# Only acts when BACKUP_TOOL=basebackup. Does nothing (exit 0) for every other value, so it is
# always safe to call: pgBackRest manages its own archive_command (pgbackrest archive-push),
# Barman support is not built yet, and BACKUP_TOOL=none means archiving has nowhere to go.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env]
Stages conf.d/06-archiving.conf (archive_mode=on, archive_command to ARCHIVE_TOP) when
BACKUP_TOOL=basebackup. A no-op for every other BACKUP_TOOL value. Never overwrites an
existing conf.d/06-archiving.conf, and never restarts EPAS.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required

case "$(_lower "${BACKUP_TOOL:-basebackup}")" in
    basebackup) ;;
    pgbackrest)
        log_info "BACKUP_TOOL=pgbackrest: archiving is pgBackRest's own job (archive_command runs" \
                 "'pgbackrest archive-push' once its stanza is set up). Nothing to do here."
        exit 0 ;;
    none)
        log_info "BACKUP_TOOL=none: no backup method is configured, so WAL archiving has nowhere" \
                 "useful to go. Set BACKUP_TOOL in site.env first."
        exit 0 ;;
    *)
        log_info "BACKUP_TOOL=${BACKUP_TOOL}: not built yet in this script. Nothing to do."
        exit 0 ;;
esac

require_vars ARCHIVE_TOP DATA_TOP
[ -d "$ARCHIVE_TOP" ] || die "ARCHIVE_TOP ${ARCHIVE_TOP} does not exist (epas-base-build-root.sh creates it)"
[ -w "$ARCHIVE_TOP" ] || die "ARCHIVE_TOP ${ARCHIVE_TOP} is not writable by $(whoami)"
[ -d "${DATA_TOP}/conf.d" ] || die "${DATA_TOP}/conf.d does not exist - run epas-base-build-db.sh first"

show_config BACKUP_TOOL ARCHIVE_TOP DATA_TOP

TARGET="${DATA_TOP}/conf.d/06-archiving.conf"
if [ -f "$TARGET" ]; then
    log_info "conf.d/06-archiving.conf already exists - keeping local version"
else
    cat > "$TARGET" <<CONF
# WAL archiving to ARCHIVE_TOP, for base backups and PITR (BACKUP_TOOL=basebackup).
# Managed by enable-wal-archiving.sh - edit freely; never overwritten on re-run.
archive_mode = on
archive_command = '${SCRIPT_DIR}/archive-wal.sh ${ARCHIVE_TOP} %p %f'
CONF
    log_info "Staged conf.d/06-archiving.conf (archive_command -> ${ARCHIVE_TOP})"
    log_audit "WAL archiving enabled for ${DATA_TOP} (archive dir ${ARCHIVE_TOP})"
fi

if systemctl is-active --quiet "${EPAS_SERVICE:-${SERVICE_NAME:-}}" 2>/dev/null; then
    log_warn "EPAS is running: archive_mode only takes effect after a RESTART (not a reload)." \
             "Schedule one with modules/03-patching/node-maintenance-stop.sh and node-maintenance-start.sh."
else
    log_info "EPAS is not running yet: archiving will be active from the first start."
fi
