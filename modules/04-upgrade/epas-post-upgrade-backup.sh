#!/usr/bin/env bash
# =============================================================================
# modules/04-upgrade/epas-post-upgrade-backup.sh - steps 9 and 10 of docs/epas-major-upgrade-efm.md
#
#   sudo -iu enterprisedb modules/04-upgrade/epas-post-upgrade-backup.sh [--env conf/site.env] [--yes]
#
# After a major upgrade the old version's backups cannot be restored on the new binaries, and its
# archived WAL does not belong to the new cluster. This script, run on the NEW primary:
#   1. checks this is the new primary (right major version, not in recovery)
#   2. checks WAL archiving is on and points at archive-wal.sh (it never restarts EPAS)
#   3. moves the old version's backups out of the way into BACKUP_TOP/pre-upgrade-epas<old>-<time>/
#      (kept, not deleted: they restore with the OLD binaries). Without this, the restore test
#      could pick one of them and fail, and retention would prune them by age.
#   4. proves archiving works now: switches the WAL file and waits for it to be archived
#   5. takes the first backup on the new version (take-basebackup.sh)
#   6. runs the restore test on it (restore-test.sh --pick latest)
#
# Old archived WAL: if the archive already holds files from the old cluster, the check in step 4 is what
# shows a clash (archive-wal.sh refuses to overwrite a different file with the same name). If it fails,
# the message says what to do.
#
# Only acts when BACKUP_TOOL=basebackup.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
BACKUP_DIR_SCRIPTS="${SCRIPT_DIR}/../06-backup"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes]
Run as SYSTEM_USER on the new primary after the upgrade has been validated: checks WAL archiving, moves the
old version's backups aside, proves archiving works, takes the first backup on the new version and runs
the restore test on it. Only runs when BACKUP_TOOL=basebackup. Never restarts EPAS.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required

case "$(_lower "${BACKUP_TOOL:-basebackup}")" in
    basebackup) ;;
    *) die "BACKUP_TOOL=${BACKUP_TOOL}: this script only handles BACKUP_TOOL=basebackup. For another tool, take a first backup on the new version with that tool's own commands." ;;
esac

require_vars SYSTEM_USER BINARY_TOP PRIMARY_PORT DATA_TOP BACKUP_TOP ARCHIVE_TOP EPAS_VERSION
[ "$(whoami)" = "$SYSTEM_USER" ] || die "Run this as ${SYSTEM_USER} (sudo -iu ${SYSTEM_USER} ...)."
[ -d "$BACKUP_TOP" ]  || die "BACKUP_TOP ${BACKUP_TOP} does not exist."
[ -d "$ARCHIVE_TOP" ] || die "ARCHIVE_TOP ${ARCHIVE_TOP} does not exist."
show_config EPAS_VERSION DATA_TOP BACKUP_TOP ARCHIVE_TOP PRIMARY_PORT

PSQL=("${BINARY_TOP}/bin/psql" -p "$PRIMARY_PORT" -d postgres -XAt)
sql() { "${PSQL[@]}" -c "$1"; }

# --- 1. Is this the new primary? --------------------------------------------------------------
NUM="$(sql 'SHOW server_version_num;' 2>/dev/null)" || die "Cannot connect to EPAS on port ${PRIMARY_PORT}. Is the new cluster running?"
NEW_MAJOR=$(( NUM / 10000 ))
[ "$NEW_MAJOR" = "$EPAS_VERSION" ] || die "The server on port ${PRIMARY_PORT} is version ${NEW_MAJOR}, but EPAS_VERSION=${EPAS_VERSION}. Run this on the upgraded cluster."
[ "$(sql 'SELECT pg_is_in_recovery();')" = "f" ] || die "This server is in recovery (a standby). Run this on the new primary."
log_info "[1/6] This is the new primary, EPAS ${NEW_MAJOR}."

# --- 2. Archiving configured? -----------------------------------------------------------------
[ "$(sql 'SHOW archive_mode;')" = "on" ] || die "archive_mode is not 'on'. Run modules/06-backup/enable-wal-archiving.sh, then restart EPAS in a planned window (modules/03-patching/node-maintenance-stop.sh and node-maintenance-start.sh), then run this again. Nothing was changed."
case "$(sql 'SHOW archive_command;')" in
    *archive-wal.sh*) ;;
    *) die "archive_command does not use archive-wal.sh: $(sql 'SHOW archive_command;'). Nothing was changed." ;;
esac
log_info "[2/6] WAL archiving is on and uses archive-wal.sh."

# --- 3. Old-version backups out of the way ----------------------------------------------------
DATE_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*'
OLD_BACKUPS=(); OLD_MAJORS=()
while IFS= read -r d; do
    [ -f "${d}/PG_VERSION" ] || continue
    v="$(tr -d '[:space:]' < "${d}/PG_VERSION")"
    if [[ "$v" =~ ^[0-9]+$ && "$v" -lt "$NEW_MAJOR" ]]; then OLD_BACKUPS+=("$d"); OLD_MAJORS+=("$v"); fi
done < <(find "$BACKUP_TOP" -maxdepth 1 -mindepth 1 -type d -name "$DATE_GLOB" | sort)

if [ "${#OLD_BACKUPS[@]}" -eq 0 ]; then
    log_info "[3/6] No backups from an older version under ${BACKUP_TOP}."
else
    OLD_V="$(printf '%s\n' "${OLD_MAJORS[@]}" | sort -n | tail -1)"
    PARK="${BACKUP_TOP}/pre-upgrade-epas${OLD_V}-$(date +%F_%H%M%S)"
    log_info "[3/6] ${#OLD_BACKUPS[@]} backup(s) from an older version (they restore only with the old binaries):"
    for d in "${OLD_BACKUPS[@]}"; do log_info "  $d"; done
    confirm_or_exit "move them into ${PARK} (kept, not deleted; the restore test and retention ignore that folder)"
    mkdir -p "$PARK"
    for d in "${OLD_BACKUPS[@]}"; do
        mv "$d" "$PARK/"
        log_audit "Moved old-version backup ${d} to ${PARK}"
    done
fi

# --- 4. Prove archiving works now -------------------------------------------------------------
BEFORE_FAILED="$(sql 'SELECT failed_count FROM pg_stat_archiver;')"
BEFORE_LAST="$(sql "SELECT coalesce(last_archived_wal,'') FROM pg_stat_archiver;")"
sql 'SELECT pg_switch_wal();' >/dev/null
ARCH_OK=0
for _ in $(seq 1 12); do
    sleep 5
    NOW_FAILED="$(sql 'SELECT failed_count FROM pg_stat_archiver;')"
    NOW_LAST="$(sql "SELECT coalesce(last_archived_wal,'') FROM pg_stat_archiver;")"
    if [ "$NOW_FAILED" -gt "$BEFORE_FAILED" ]; then break; fi
    if [ -n "$NOW_LAST" ] && [ "$NOW_LAST" != "$BEFORE_LAST" ]; then ARCH_OK=1; break; fi
done
if [ "$ARCH_OK" != 1 ]; then
    die "WAL archiving did not archive the switched WAL file within 60 seconds (pg_stat_archiver: last failed = $(sql "SELECT coalesce(last_failed_wal,'none') FROM pg_stat_archiver;")). The usual cause after an upgrade is an old file with the same name in ${ARCHIVE_TOP}: archive-wal.sh refuses to overwrite it. See the toolkit log for 'refusing to overwrite'. If so: with the old cluster signed off or backed up elsewhere, move the old files into a dated folder inside ${ARCHIVE_TOP} (archive-wal.sh only uses the top level), then run this again. No backup was taken."
fi
log_info "[4/6] Archiving works: ${NOW_LAST} archived."

# --- 5. First backup on the new version -------------------------------------------------------
ARGS=(); [ -n "${ENV_SOURCE:-}" ] && ARGS+=(--env "$(readlink -f "$ENV_SOURCE")"); [ "$ASSUME_YES" = "1" ] && ARGS+=(--yes)
log_info "[5/6] Taking the first EPAS ${NEW_MAJOR} backup"
bash "${BACKUP_DIR_SCRIPTS}/take-basebackup.sh" "${ARGS[@]+"${ARGS[@]}"}" "post-upgrade-epas${NEW_MAJOR}"

# --- 6. Restore test on it --------------------------------------------------------------------
log_info "[6/6] Running the restore test on the newest backup"
bash "${BACKUP_DIR_SCRIPTS}/restore-test.sh" "${ARGS[@]+"${ARGS[@]}"}" --pick latest

log_audit "Post-upgrade backup and restore test finished for EPAS ${NEW_MAJOR} on $(hostname -s)"
log_info "Done. Old-version backups are in ${BACKUP_TOP}/pre-upgrade-* until you delete them after sign-off."
