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
# HOW A RUN GOES
#   1. choose the backup, then check everything BEFORE spending time on a copy:
#      settings -> binaries -> which backup -> free space -> no tablespaces ->
#      TDE passphrase file -> pg_verifybackup
#   2. copy it into RESTORE_TOP (low priority), start a small isolated instance on the copy,
#      replay ALL archived WAL, check the instance is out of recovery and can write
#   3. whatever the outcome, write an evidence file; PASS deletes the copy, FAIL keeps it
#
# Exit code: 0 = pass, 1 = fail. Evidence: <log directory>/restore-tests/<date>_<cluster>_PASS|FAIL.txt
# (or RESTORE_EVIDENCE_DIR). A --check-only run restores nothing and writes no evidence.
#
# Scheduling (cron, as SYSTEM_USER): the latest backup daily or weekly, --pick random now and then.
# Run it outside business hours: it shares the server's disks with the live database.
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
  RESTORE_EVIDENCE_DIR        where the evidence files go (default <log directory>/restore-tests)
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
RESTORE_DIR=""; RESTORE_LOG=""; SOCK_DIR=""; STARTED=0
WAL_FILES=0; REDO_LINE=""; LAST_TX=""; COPY_STATE="none made"
START_STAMP="$(date +%Y%m%d-%H%M%S)"; START_ISO="$(date -Is)"

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
# =============================================================================
# STEP 3: whatever happens, leave evidence, and clean up by one rule:
#   PASS -> the temporary copy is deleted (it has served its purpose)
#   FAIL -> the copy is kept, so you can look at the instance log and the files
# =============================================================================
# remove_copy DIR - delete a copy this script made. Refuses anything that is not
# exactly <RESTORE_TOP>/<date>_<time>_of_<backup name>, so a wrong variable can never delete real data.
remove_copy() {
    local d="$1"
    case "$d" in
        "${RESTORE_TOP%/}"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*_of_*) ;;
        *) log_warn "Not removing ${d}: it is not where this script makes restore copies."; return 1 ;;
    esac
    rm -rf "$d"
}

# evidence_dir - where the proof of each run goes: next to the toolkit logs, else beside the backups.
evidence_dir() {
    local d="${RESTORE_EVIDENCE_DIR:-}" l
    if [ -z "$d" ]; then
        l="$(log_dir)"
        if [ -n "$l" ] && [ -d "$l" ] && [ -w "$l" ]; then d="${l}/restore-tests"; else d="${BACKUP_TOP}/restore-tests"; fi
    fi
    printf '%s\n' "$d"
}

# write_evidence - one small text file per run: what was tested, how it ended, how long it took.
# It holds no secret: the passphrase FILE'S PATH is named, never what is inside it.
write_evidence() {
    local dir file res
    dir="$(evidence_dir)"
    res="$(printf '%s' "$RESULT" | tr '[:lower:]' '[:upper:]')"
    file="${dir}/${START_STAMP}_${CLUSTER_NAME}_${res}.txt"
    if ! ( umask 027; mkdir -p "$dir" && cat > "$file" ) 2>/dev/null <<EVIDENCE
restore_test_result=${res}
cluster=${CLUSTER_NAME}
host=$(hostname -s 2>/dev/null || hostname)
epas_version=${EPAS_VERSION}
app_code=${APP_CODE:-}
started=${START_ISO}
finished=$(date -Is)
duration_seconds=${SECONDS}
backup=${BACKUP_NAME}
backup_pick=${PICK}
backup_size_bytes=${BACKUP_BYTES}
tde=$([ "$TDE_FOUND" = "1" ] && echo yes || echo no)
tde_passphrase_file=${TDE_PASS_PATH:-}
wal_files_replayed=${WAL_FILES}
recovery=${REDO_LINE}
last_transaction=${LAST_TX}
timeout_hours=${RESTORE_TEST_TIMEOUT_HOURS}
copy=${COPY_STATE}
failure_reason=${FAIL_REASON}
toolkit_log=${TOOLKIT_LOG_FILE:-}
EVIDENCE
    then
        log_warn "Could not write the evidence file in ${dir}. The result is in the log above."
        return 0
    fi
    log_info "Evidence written: ${file}"
    log_audit "Restore test ${res}: ${BACKUP_NAME}; evidence ${file}"
}

# on_exit - runs when the script ends for ANY reason (success, failure, Ctrl-C, an unexpected error).
on_exit() {
    local rc=$?
    set +e
    # 1. never leave the temporary instance running, never leave its socket folder behind
    if [ "$STARTED" = "1" ] && [ -n "$RESTORE_DIR" ] && "${BIN}/pg_ctl" status -D "$RESTORE_DIR" >/dev/null 2>&1; then
        "${BIN}/pg_ctl" stop -D "$RESTORE_DIR" -m immediate -w -t 60 >/dev/null 2>&1
    fi
    if [ -n "$SOCK_DIR" ]; then rm -rf "$SOCK_DIR"; fi
    # 2. a run that did not reach its own "pass" is a failure
    if [ -z "$RESULT" ]; then
        RESULT="fail"
        [ -n "$FAIL_REASON" ] || FAIL_REASON="the script stopped unexpectedly (exit code ${rc})"
    fi
    # 3. the copy: deleted on a pass, kept on a failure
    if [ -n "$RESTORE_DIR" ] && [ -d "$RESTORE_DIR" ]; then
        if [ "$RESULT" = "pass" ]; then
            if remove_copy "$RESTORE_DIR"; then
                COPY_STATE="removed"; log_info "Test copy removed: ${RESTORE_DIR}"
            else
                COPY_STATE="kept (could not be removed): ${RESTORE_DIR}"
            fi
        else
            COPY_STATE="kept for investigation: ${RESTORE_DIR}"
            log_warn "Test FAILED. The copy is kept for investigation: ${RESTORE_DIR} (instance log: ${RESTORE_LOG:-none}). When done:  $0 --remove-kept"
        fi
    else
        COPY_STATE="none made"
    fi
    # 4. evidence (a --check-only run proved nothing about restoring, so it leaves none)
    if [ "$RESULT" != "checks-only" ]; then write_evidence; fi
    return 0
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

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
    RESULT="checks-only"
    log_info "--check-only: all checks passed for ${BACKUP_NAME}. Nothing was restored."
    exit 0
fi

# >>> RESTORE (step 2)
# =============================================================================
# STEP 2: copy the backup, start a small isolated instance on it, wait for the WAL replay
# =============================================================================
RESTORE_DIR="${RESTORE_TOP}/$(date +%F_%H%M%S)_of_${BACKUP_NAME}"
RESTORE_LOG="${RESTORE_DIR}/restore-test.log"
TIMEOUT_SECS="${RESTORE_TEST_TIMEOUT_SECS:-$TIMEOUT_SECS}"     # RESTORE_TEST_TIMEOUT_SECS and ..._POLL_SECS: for the unit tests
POLL_SECS="${RESTORE_TEST_POLL_SECS:-10}"

# The test runs on the same server as the real database: ask the OS to give production the
# first call on CPU and disk. nice = CPU, ionice class 2 level 7 = lowest priority for disk.
LOWPRIO=(nice -n 19)
if command -v ionice >/dev/null 2>&1; then LOWPRIO+=(ionice -c2 -n7); fi

# Is something already listening on the test port? pg_isready: 0 accepting, 1 starting up,
# 2 no answer. Only 2 means the port is free.
READY_RC=0
"${BIN}/pg_isready" -q -h localhost -p "$RESTORE_TEST_PORT" || READY_RC=$?
[ "$READY_RC" -ge 2 ] || fail_run "Something already answers on port ${RESTORE_TEST_PORT} (a test that is still running?). Choose another RESTORE_TEST_PORT or wait. Nothing was copied."

log_audit "Restore test started by $(whoami): ${BACKUP_NAME} -> ${RESTORE_DIR}"
log_info "Copying ${BACKUP_NAME} to ${RESTORE_DIR} at low priority ..."
CSTART=$SECONDS
"${LOWPRIO[@]}" cp -a "$BACKUP_DIR" "$RESTORE_DIR" || fail_run "Copying the backup into ${RESTORE_DIR} failed."
chmod 700 "$RESTORE_DIR"                   # PostgreSQL refuses a data directory others can read
rm -f "${RESTORE_DIR}/postmaster.pid"
# recovery.signal = "this is a restore: replay WAL from restore_command". No recovery target
# is set, so PostgreSQL replays EVERY WAL file it can find and then promotes itself.
touch "${RESTORE_DIR}/recovery.signal"
log_info "Copy done in $(( SECONDS - CSTART )) s."

SOCK_DIR="$(mktemp -d /tmp/edb-restore-test.XXXXXX)"
chmod 700 "$SOCK_DIR"                      # a short path on purpose: socket paths are limited to ~100 characters

# Settings given on the command line beat every config file in the copy, so the production
# configuration the copy still contains can never take effect. Why each one:
#   port, listen_addresses, unix_socket_*  its own port, this machine only, own socket folder
#   archive_mode=off, archive_command       NEVER write into the real WAL archive
#   restore_command                         read the WAL from the real archive (read only)
#   hot_standby=off                         no check against the source's connection settings
#   max_connections, shared_buffers, huge_pages  small, and no dependency on huge pages
#   max_wal_senders=0, primary_conninfo, synchronous_standby_names   no replication of any kind
#   logging_collector=off, ssl=off, external_pid_file   nothing outside the copy and the socket folder
#   autovacuum, fsync, full_page_writes, synchronous_commit   off: only for a copy we throw away.
#                                           NEVER do this on a real database - a crash would corrupt it.
PG_SETTINGS=(
    "port=${RESTORE_TEST_PORT}" "listen_addresses=localhost"
    "unix_socket_directories=${SOCK_DIR}" "unix_socket_permissions=0700"
    "archive_mode=off" "archive_command=/bin/false"
    "restore_command='cp ${ARCHIVE_TOP}/%f %p'"
    "hot_standby=off" "max_connections=5" "shared_buffers=128MB" "huge_pages=off"
    "max_wal_senders=0" "primary_conninfo=''" "synchronous_standby_names=''"
    "logging_collector=off" "ssl=off" "external_pid_file=''" "cluster_name=restore_test"
    "autovacuum=off" "fsync=off" "full_page_writes=off" "synchronous_commit=off"
)
PG_OPTS=""
for s in "${PG_SETTINGS[@]}"; do PG_OPTS+=" -c ${s}"; done

log_info "Starting the temporary instance on port ${RESTORE_TEST_PORT} (limit ${RESTORE_TEST_TIMEOUT_HOURS} h) ..."
RSTART=$SECONDS
STARTED=1
"${LOWPRIO[@]}" "${BIN}/pg_ctl" start -D "$RESTORE_DIR" -l "$RESTORE_LOG" -o "$PG_OPTS" -W >/dev/null \
    || fail_run "pg_ctl could not start the temporary instance. See ${RESTORE_LOG}."

# While WAL is being replayed the instance does not accept connections (hot_standby=off).
# It starts answering only when replay has finished and it has promoted itself.
DEADLINE=$(( SECONDS + TIMEOUT_SECS )); NEXT_NOTE=$(( SECONDS + 300 ))
while ! "${BIN}/pg_isready" -q -h "$SOCK_DIR" -p "$RESTORE_TEST_PORT"; do
    if ! "${BIN}/pg_ctl" status -D "$RESTORE_DIR" >/dev/null 2>&1; then
        STARTED=0
        [ ! -f "$RESTORE_LOG" ] || tail -n 15 "$RESTORE_LOG" | while IFS= read -r l; do log_error "  instance log: ${l}"; done
        fail_run "The temporary instance stopped before recovery finished (a missing or damaged WAL file, or a wrong key). Log: ${RESTORE_LOG}"
    fi
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
        fail_run "Timed out: recovery was not finished after ${RESTORE_TEST_TIMEOUT_HOURS} h. The copy is kept: ${RESTORE_DIR}"
    fi
    if [ "$SECONDS" -ge "$NEXT_NOTE" ]; then
        log_info "Still replaying WAL: $(grep -c 'restored log file' "$RESTORE_LOG" 2>/dev/null || true) file(s) so far, $(( (SECONDS - RSTART) / 60 )) min."
        NEXT_NOTE=$(( SECONDS + 300 ))
    fi
    sleep "$POLL_SECS"
done
log_info "Recovery finished after $(( SECONDS - RSTART )) s: the instance accepts connections."

# --- Is it a normal, writable database now? ---------------------------------------------------------
PSQL=("${BIN}/psql" -X -h "$SOCK_DIR" -p "$RESTORE_TEST_PORT" -U "$SYSTEM_USER" -d template1 -Atq)
IN_RECOVERY="$("${PSQL[@]}" -c 'select pg_is_in_recovery()' 2>&1)" || fail_run "Cannot query the temporary instance: ${IN_RECOVERY}"
[ "$IN_RECOVERY" = "f" ] || fail_run "The temporary instance is still in recovery (pg_is_in_recovery=${IN_RECOVERY}); it did not finish."
WROTE="$("${PSQL[@]}" -c 'create temp table restore_probe(i int); insert into restore_probe values (1); select count(*) from restore_probe' 2>&1)" \
    || fail_run "The temporary instance could not write: ${WROTE}"
[ "$WROTE" = "1" ] || fail_run "Write test on the temporary instance gave '${WROTE}', expected 1."

WAL_FILES="$(grep -c 'restored log file' "$RESTORE_LOG" 2>/dev/null || true)"; WAL_FILES="${WAL_FILES:-0}"
REDO_LINE="$(grep -E 'redo done at' "$RESTORE_LOG" 2>/dev/null | tail -1 | sed 's/^.*redo done at/redo done at/' || true)"
LAST_TX="$(grep -E 'last completed transaction was at log time' "$RESTORE_LOG" 2>/dev/null | tail -1 | sed 's/^.*last completed transaction was at log time/last completed transaction at/' || true)"
log_info "Replayed ${WAL_FILES} archived WAL file(s). ${REDO_LINE}${LAST_TX:+; ${LAST_TX}}"

"${BIN}/pg_ctl" stop -D "$RESTORE_DIR" -m fast -w -t 300 >/dev/null 2>&1 && STARTED=0 \
    || log_warn "The temporary instance did not stop cleanly; the exit handler will stop it hard."
RESULT="pass"
log_info "RESTORE TEST PASSED: ${BACKUP_NAME} restores and its WAL replays ($(( SECONDS )) s in all)."
exit 0                                     # on_exit removes the copy and writes the evidence
# <<< RESTORE (step 2)
