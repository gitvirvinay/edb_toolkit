#!/usr/bin/env bash
# =============================================================================
# modules/06-backup/restore-test.sh - prove that a base backup really restores
#
#   modules/06-backup/restore-test.sh [--env conf/site.env] [--pick latest|random]
#                                     [--check-only] [--remove-kept]
#
# WHY: a backup that has never been restored is a hope, not a backup. This script restores
# one backup into a throw-away copy, replays ALL the archived WAL on top of it, starts a
# small temporary instance from it and checks that the instance comes up as a normal,
# writable database. A pass proves the base backup AND the WAL archive work together.
#
# Only acts when BACKUP_TOOL=basebackup. Run as SYSTEM_USER (the database OS user); needs no root.
#
# What it never does:
#   - touches the real database, the real archive or the backups: it only READS them;
#   - archives anything: the temporary instance runs with archive_mode=off, on its own port,
#     listening on localhost only, so it can never write into the real WAL archive;
#   - copies, prints or logs the TDE passphrase: it only checks that the file is there.
#
# STEP 1 (this part): choose the backup, then check everything BEFORE spending time on a copy:
#   settings -> binaries -> which backup -> free space -> TDE passphrase file -> pg_verifybackup
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--pick latest|random] [--check-only] [--remove-kept]

Restores one base backup from BACKUP_TOP into a temporary copy, replays all archived WAL and
starts a small temporary instance to prove it works. Only runs when BACKUP_TOOL=basebackup.
Run as SYSTEM_USER (no root needed).

  --pick latest   (default) the newest complete backup - the one you would use in a disaster
  --pick random   any complete backup on disk: a deeper test, it replays more WAL
  --check-only    do the safety checks only (space, passphrase file, pg_verifybackup); restore nothing
  --remove-kept   delete the copies earlier failed runs left behind for investigation, then stop

Settings (conf/site.env, all optional):
  RESTORE_TEST_TIMEOUT_HOURS  give up after this many hours (default 4)
  RESTORE_TEST_PORT           port of the temporary instance (default 55432)
  RESTORE_TEST_KEEP_MAX       stop starting new tests while this many failed copies are still kept (default 1)
  RESTORE_TOP                 where the temporary copy lives (default BACKUP_TOP/restore-test)
USAGE
    exit 0
}

PICK="latest"; CHECK_ONLY=0; REMOVE_KEPT=0
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage ;;
        --pick)       [ -n "${2:-}" ] || die "--pick needs latest or random"; PICK="$2"; shift 2 ;;
        --pick=*)     PICK="${1#--pick=}"; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --remove-kept) REMOVE_KEPT=1; shift ;;
        *)            die "Unknown option: $1 (see --help)" ;;
    esac
done
_one_of "$PICK" latest random || die "--pick must be 'latest' or 'random' (not '${PICK}')"
load_env required

# --- Only for BACKUP_TOOL=basebackup, only as the database OS user ------------------------------
case "$BACKUP_TOOL" in
    basebackup) ;;
    *) die "BACKUP_TOOL=${BACKUP_TOOL} - this script tests base backups (BACKUP_TOOL=basebackup). Use the restore procedure of your actual backup tool." ;;
esac
require_vars DATA_TOP BACKUP_TOP ARCHIVE_TOP SYSTEM_USER BINARY_TOP PRIMARY_PORT
[ "$(whoami)" = "$SYSTEM_USER" ] || die "Run this as ${SYSTEM_USER} (sudo -iu ${SYSTEM_USER} ...): the temporary instance must be owned by the database OS user."

# --- Settings and their defaults ----------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-as${EPAS_VERSION}}"
RESTORE_TEST_TIMEOUT_HOURS="${RESTORE_TEST_TIMEOUT_HOURS:-4}"
RESTORE_TEST_PORT="${RESTORE_TEST_PORT:-55432}"
RESTORE_TEST_KEEP_MAX="${RESTORE_TEST_KEEP_MAX:-1}"
RESTORE_TOP="${RESTORE_TOP:-${BACKUP_TOP}/restore-test}"
BIN="${BINARY_TOP}/bin"
TIMEOUT_SECS=0                    # set below, once RESTORE_TEST_TIMEOUT_HOURS is known to be a number

# What the run knows about itself; the evidence file (step 3) is written from these.
RESULT=""                         # pass | fail
FAIL_REASON=""
BACKUP_DIR=""; BACKUP_NAME=""; BACKUP_BYTES=0
TDE_FOUND=0; TDE_PASS_PATH=""

# fail_run "reason" - stop this run as a FAILURE, saying why (step 3 records it as evidence).
fail_run() { FAIL_REASON="$*"; die "$*"; }

DATE_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*'     # how backups and kept copies are named

validate_settings_restore() {
    local bad=()
    [[ "$RESTORE_TEST_TIMEOUT_HOURS" =~ ^[1-9][0-9]*$ ]] || bad+=("RESTORE_TEST_TIMEOUT_HOURS='${RESTORE_TEST_TIMEOUT_HOURS}' (whole hours, at least 1)")
    [[ "$RESTORE_TEST_KEEP_MAX" =~ ^[1-9][0-9]*$ ]]      || bad+=("RESTORE_TEST_KEEP_MAX='${RESTORE_TEST_KEEP_MAX}' (a whole number, at least 1)")
    if [[ "$RESTORE_TEST_PORT" =~ ^[0-9]+$ ]] && [ "$RESTORE_TEST_PORT" -ge 1024 ] && [ "$RESTORE_TEST_PORT" -le 65535 ]; then
        [ "$RESTORE_TEST_PORT" != "$PRIMARY_PORT" ] || bad+=("RESTORE_TEST_PORT='${RESTORE_TEST_PORT}' is the real database's port")
    else
        bad+=("RESTORE_TEST_PORT='${RESTORE_TEST_PORT}' (a port from 1024 to 65535)")
    fi
    # These two paths go inside the restore_command of the temporary instance: keep them plain.
    local p
    for p in ARCHIVE_TOP RESTORE_TOP; do
        [[ "${!p}" =~ ^/[A-Za-z0-9._/-]+$ && "${!p}" != *..* ]] || bad+=("${p}='${!p}' (absolute path; letters, digits and . _ - / only)")
    done
    # The restore area must never be a place that holds real data.
    for p in "$BACKUP_TOP" "$ARCHIVE_TOP" "$DATA_TOP" "${WAL_TOP:-}"; do
        [ -z "$p" ] || [ "${RESTORE_TOP%/}" != "${p%/}" ] || bad+=("RESTORE_TOP='${RESTORE_TOP}' is the same as a real data folder")
    done
    if [ "${#bad[@]}" -gt 0 ]; then
        die "Invalid setting(s) in ${ENV_SOURCE:-the environment}: ${bad[*]}. Nothing was done."
    fi
    TIMEOUT_SECS=$(( RESTORE_TEST_TIMEOUT_HOURS * 3600 ))
}
validate_settings_restore

for t in pg_ctl pg_isready psql pg_verifybackup; do
    [ -x "${BIN}/${t}" ] || die "${BIN}/${t} not found - check BINARY_TOP in ${ENV_SOURCE:-the config}."
done

# --- Copies that earlier FAILED runs left behind (kept on purpose, so you can investigate) --------
kept_copies() {
    find "$RESTORE_TOP" -maxdepth 1 -mindepth 1 -type d -name "$DATE_GLOB" 2>/dev/null | sort || true
}
mapfile -t KEPT < <(kept_copies)

if [ "$REMOVE_KEPT" = "1" ]; then
    if [ "${#KEPT[@]}" -eq 0 ]; then log_info "No kept restore copies under ${RESTORE_TOP}."; exit 0; fi
    log_info "Kept restore copies under ${RESTORE_TOP}:"
    for d in "${KEPT[@]}"; do log_info "  ${d}"; done
    confirm_destructive "delete the ${#KEPT[@]} kept restore copy(ies) listed above"
    for d in "${KEPT[@]}"; do
        rm -rf "$d"
        log_audit "Removed kept restore copy: ${d}"
    done
    exit 0
fi
if [ "${#KEPT[@]}" -ge "$RESTORE_TEST_KEEP_MAX" ]; then
    log_error "A failed restore copy from an earlier run is still kept (${#KEPT[@]} of ${RESTORE_TEST_KEEP_MAX} allowed):"
    for d in "${KEPT[@]}"; do log_error "  ${d}"; done
    die "Look at why it failed, then delete it with:  $0 --remove-kept   (or raise RESTORE_TEST_KEEP_MAX). No new test was started, so failed copies cannot fill the disk."
fi

# --- Which backup? --------------------------------------------------------------------------------
# A backup is complete when pg_basebackup left both backup_label and backup_manifest in it.
# One still being written, or one that failed half way, has no manifest and is never chosen.
# Names are YYYY-MM-DD_HHMMSS_tag, so a plain sort puts the newest last.
list_backups() {
    find "$BACKUP_TOP" -maxdepth 1 -mindepth 1 -type d -name "$DATE_GLOB" \
         -exec test -f '{}/backup_label' ';' -exec test -f '{}/backup_manifest' ';' -print 2>/dev/null | sort || true
}
mapfile -t CANDIDATES < <(list_backups)
[ "${#CANDIDATES[@]}" -gt 0 ] || die "No complete backup found under ${BACKUP_TOP} (needs backup_label and backup_manifest). Take one with take-basebackup.sh first."

if [ "$PICK" = "random" ]; then
    BACKUP_DIR="${CANDIDATES[$(( RANDOM % ${#CANDIDATES[@]} ))]}"
else
    BACKUP_DIR="${CANDIDATES[$(( ${#CANDIDATES[@]} - 1 ))]}"
fi
BACKUP_NAME="$(basename "$BACKUP_DIR")"
show_config CLUSTER_NAME BACKUP_TOP ARCHIVE_TOP RESTORE_TOP RESTORE_TEST_PORT RESTORE_TEST_TIMEOUT_HOURS
log_info "Backup chosen (--pick ${PICK}, ${#CANDIDATES[@]} complete backup(s) on disk): ${BACKUP_NAME}"
[ -d "$ARCHIVE_TOP" ] || fail_run "ARCHIVE_TOP ${ARCHIVE_TOP} does not exist - there is no WAL to replay."

# --- Check 1: free space ---------------------------------------------------------------------------
# The copy needs about the size of the backup, plus 20% for what the WAL replay adds.
mkdir -p "$RESTORE_TOP"
BACKUP_BYTES=$(du -sb "$BACKUP_DIR" | cut -f1)
AVAIL_BYTES=$(df --output=avail -B1 "$RESTORE_TOP" | tail -1 | tr -d ' ')
NEEDED_BYTES=$(( BACKUP_BYTES + BACKUP_BYTES / 5 ))
if [ "${AVAIL_BYTES:-0}" -lt "$NEEDED_BYTES" ]; then
    fail_run "Not enough space on ${RESTORE_TOP}: ${AVAIL_BYTES} bytes free, need about ${NEEDED_BYTES} (the backup is ${BACKUP_BYTES} bytes). Nothing was copied."
fi
log_info "Check 1 ok - free space: ${AVAIL_BYTES} bytes free, about ${NEEDED_BYTES} needed."

# --- Check 2: no tablespaces ---------------------------------------------------------------------
# A tablespace is stored OUTSIDE the data directory and linked by its real path. A restored copy
# would use the same real path as the production database - it could overwrite live data.
if [ -d "${BACKUP_DIR}/pg_tblspc" ] && [ -n "$(ls -A "${BACKUP_DIR}/pg_tblspc" 2>/dev/null)" ]; then
    fail_run "${BACKUP_NAME} contains tablespaces (pg_tblspc is not empty). A restore test would write to the same paths as the live database, so it refuses. Tablespaces need a mapped restore - not supported by this script."
fi
log_info "Check 2 ok - the backup has no tablespaces."

# --- Check 3: TDE passphrase file -------------------------------------------------------------------
# A TDE backup holds the data and the WRAPPED key, not the passphrase. The instance needs the
# passphrase file to start (data_encryption_key_unwrap_command in postgresql.conf says where).
# We only look that the file is there and readable. We never print, copy or log what is in it.
UNWRAP_LINE="$(grep -hs -E '^[[:space:]]*data_encryption_key_unwrap_command' \
                    "${BACKUP_DIR}/postgresql.conf" "${BACKUP_DIR}"/conf.d/*.conf "${BACKUP_DIR}/postgresql.auto.conf" 2>/dev/null | tail -1 || true)"
if [ -n "$UNWRAP_LINE" ]; then
    TDE_FOUND=1
    TDE_PASS_PATH="$(printf '%s' "$UNWRAP_LINE" | grep -oE "file:[^ '\"]+" | head -1 | cut -c6- || true)"
    if [ -z "$TDE_PASS_PATH" ]; then
        log_warn "Check 3 - TDE is on, but the unwrap command does not read a passphrase file (a key manager?). Not checked here; the start of the temporary instance will show whether the key can be unwrapped."
    elif [ ! -f "$TDE_PASS_PATH" ]; then
        fail_run "TDE passphrase file ${TDE_PASS_PATH} does not exist on this server. Without it this backup cannot be restored here or anywhere. Get it back from your escrow copy first."
    elif [ ! -r "$TDE_PASS_PATH" ] || [ ! -s "$TDE_PASS_PATH" ]; then
        fail_run "TDE passphrase file ${TDE_PASS_PATH} is empty or not readable by $(whoami)."
    else
        log_info "Check 3 ok - TDE passphrase file is present and readable: ${TDE_PASS_PATH} (contents not read)."
    fi
else
    log_info "Check 3 ok - no TDE unwrap command in the backup's configuration: nothing to check."
fi

# --- Check 4: pg_verifybackup ----------------------------------------------------------------------
# Compares every file in the backup with the manifest (size and checksum) and, for a backup
# without TDE, reads its WAL. Seconds to minutes, and it catches a damaged backup before the copy.
# With TDE the WAL is encrypted, so the tool cannot read it: --no-parse-wal.
VARGS=()
if [ "$TDE_FOUND" = "1" ]; then VARGS+=(--no-parse-wal); fi
log_info "Check 4 - pg_verifybackup ${VARGS[*]-} ${BACKUP_NAME} ..."
VSTART=$SECONDS
if VOUT="$("${BIN}/pg_verifybackup" "${VARGS[@]+"${VARGS[@]}"}" "$BACKUP_DIR" 2>&1)"; then
    log_info "Check 4 ok - ${VOUT} ($(( SECONDS - VSTART )) s)"
else
    log_error "pg_verifybackup said: ${VOUT}"
    fail_run "pg_verifybackup found a problem in ${BACKUP_NAME}. This backup is damaged or incomplete."
fi

if [ "$CHECK_ONLY" = "1" ]; then
    log_info "--check-only: all checks passed for ${BACKUP_NAME}. Nothing was restored."
    exit 0
fi

# >>> RESTORE (step 2)
log_info "All checks passed for ${BACKUP_NAME}. The restore itself is added in the next change."
exit 0
# <<< RESTORE (step 2)
