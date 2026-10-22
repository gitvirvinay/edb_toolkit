#!/usr/bin/env bash
# epas-major-pgrestore.sh — major version upgrade by logical dump/restore (pg_dump -> pg_restore).
# Both clusters run side by side: OLD on OLD_PORT, NEW on PRIMARY_PORT. The NEW cluster must already exist
# (built with 01-provision/epas-base-build.sh, which also handles initdb, TDE and conf.d).
# The old cluster is only read, never changed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

REQUIRE_ROOT=false
JOBS=""
DUMP_DIR=""
KEEP_DUMPS=false
ALLOW_PLAIN_TARGET=false
SELECTED_DBS=()

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--root] [--jobs N] [--db NAME ...] [--dump-dir DIR] [--keep-dumps]
          [--allow-unencrypted-target] [--yes]
Copies roles/tablespaces and every connectable database from the OLD cluster (EPAS OLD_EPAS_VERSION, port OLD_PORT)
into the already-built NEW cluster (EPAS EPAS_VERSION, port PRIMARY_PORT), then rebuilds statistics and compares
object counts. Uses the NEW version's pg_dump/pg_restore (directory format, parallel). The old cluster is not changed.
  --root        run as root (tools run via 'sudo -u SYSTEM_USER'); otherwise run as SYSTEM_USER.
  --jobs N      parallel dump/restore jobs per database (default: CPU count, max 8).
  --db NAME     only migrate this database (repeatable). Default: all databases that allow connections.
  --dump-dir D  where dumps and logs go (default: <parent of DATA_TOP>/pgrestore_<timestamp>; never /tmp).
  --keep-dumps  keep the dump files after a successful restore (logs are always kept).
  --allow-unencrypted-target  allow a TDE-encrypted old cluster to be restored into a non-TDE new cluster.
  --yes         skip the confirmation questions.
Config is required (default conf/site.env): OLD_EPAS_VERSION, OLD_PORT, OLD_DATA_TOP, OLD_SERVICE_NAME,
EPAS_VERSION, DATA_TOP, SRC_BINARY_DIR, SERVICE_NAME, SYSTEM_USER, PRIMARY_PORT.
Applications should stop writing to the old cluster before you start: changes made during the dump are not copied.
USAGE
    exit 0
}

parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)       REQUIRE_ROOT=true; shift ;;
        --jobs)       [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--jobs needs a positive number"; JOBS="$2"; shift 2 ;;
        --db)         [ -n "${2:-}" ] || die "--db needs a database name"; SELECTED_DBS+=("$2"); shift 2 ;;
        --dump-dir)   [ -n "${2:-}" ] || die "--dump-dir needs a path"; DUMP_DIR="$2"; shift 2 ;;
        --keep-dumps) KEEP_DUMPS=true; shift ;;
        --allow-unencrypted-target) ALLOW_PLAIN_TARGET=true; shift ;;
        -h|--help)    usage ;;
        *)            die "Unknown argument: $1 (see --help)" ;;
    esac
done

# --- CONFIG ---
load_env required
require_vars OLD_EPAS_VERSION OLD_PORT OLD_DATA_TOP EPAS_VERSION DATA_TOP SRC_BINARY_DIR SYSTEM_USER PRIMARY_PORT
OLD_SERVICE="${OLD_SERVICE_NAME:-edb-as-${OLD_EPAS_VERSION}}"
OLD_DATA="${OLD_DATA_TOP}"
NEW_SERVICE="${SERVICE_NAME}"
NEW_BIN="${SRC_BINARY_DIR}/bin"
NEW_DATA="${DATA_TOP}"
NEW_PORT="${PRIMARY_PORT}"
[ -n "$JOBS" ] || { JOBS=$(nproc 2>/dev/null || echo 4); [ "$JOBS" -le 8 ] || JOBS=8; }
TS=$(date +%Y%m%d_%H%M%S)
DUMP_DIR="${DUMP_DIR:-$(dirname "$NEW_DATA")/pgrestore_${TS}}"

[[ "$OLD_EPAS_VERSION" =~ ^[0-9]+$ && "$OLD_EPAS_VERSION" -lt "$EPAS_VERSION" ]] \
    || die "OLD_EPAS_VERSION (${OLD_EPAS_VERSION}) must be lower than EPAS_VERSION (${EPAS_VERSION})."
[ "$OLD_PORT" != "$NEW_PORT" ] || die "OLD_PORT and PRIMARY_PORT are both ${NEW_PORT}: the two clusters must run on different ports."
for t in pg_dump pg_dumpall pg_restore psql pg_isready vacuumdb; do
    [[ -x "$NEW_BIN/$t" ]] || die "Not found: $NEW_BIN/$t (the NEW version's client tools are used for both clusters)"
done
[[ -f "$NEW_DATA/PG_VERSION" ]] || die "New cluster not initialised: $NEW_DATA/PG_VERSION (build it first with 01-provision/epas-base-build.sh)"
case "$(cd "$(dirname "$DUMP_DIR")" 2>/dev/null && pwd)/" in
    /tmp/*|/var/tmp/*) die "--dump-dir must not be under /tmp or /var/tmp (dumps can be large and contain all your data)." ;;
esac
case "$DUMP_DIR/" in
    "$OLD_DATA"/*|"$NEW_DATA"/*) die "--dump-dir must not be inside a data directory: $DUMP_DIR" ;;
esac

# --- USER CONTEXT (same rules as epas-major-pgupgrade.sh) ---
if [ "$REQUIRE_ROOT" = true ]; then
    require_root
    EXEC_CMD=(sudo -u "$SYSTEM_USER")
else
    [ "$(whoami)" != "root" ] || die "Do not run as root without --root. Execute as '${SYSTEM_USER}' or pass --root."
    [ "$(whoami)" == "$SYSTEM_USER" ] || die "Script must be executed as '${SYSTEM_USER}' (currently: $(whoami))."
    EXEC_CMD=()
fi
run()  { "${EXEC_CMD[@]+"${EXEC_CMD[@]}"}" "$@"; }
# q PORT DB SQL — one value/row per line, stops on error
q()    { run "$NEW_BIN/psql" -X -q -A -t -v ON_ERROR_STOP=1 -p "$1" -d "$2" -c "$3"; }
ready() { run "$NEW_BIN/pg_isready" -q -p "$1"; }
systemctl_cmd() { if [ "$REQUIRE_ROOT" = true ]; then systemctl "$@"; else sudo systemctl "$@"; fi; }

# ensure_running PORT SERVICE LABEL
ensure_running() {
    local port="$1" svc="$2" label="$3" i
    ready "$port" && return 0
    confirm_or_exit "${label} cluster is not accepting connections on port ${port} - start ${svc}"
    systemctl_cmd start "$svc"
    for ((i = 1; i <= 24; i++)); do
        ready "$port" && { log_info "${label} cluster is up on port ${port}."; return 0; }
        sleep 5
    done
    die "${svc} did not accept connections on port ${port}. Check: journalctl -u ${svc}"
}

# --- TDE: plain-text dumps of an encrypted cluster; never silently drop encryption ---
OLD_TDE=false; run test -f "$OLD_DATA/pg_encryption/key.bin" && OLD_TDE=true
NEW_TDE=false; run test -f "$NEW_DATA/pg_encryption/key.bin" && NEW_TDE=true
if [[ "$OLD_TDE" == true && "$NEW_TDE" == false && "$ALLOW_PLAIN_TARGET" == false ]]; then
    die "The old cluster is TDE-encrypted but the new one is not: the data would no longer be encrypted at rest. Rebuild the new cluster with TDE, or pass --allow-unencrypted-target."
fi

show_config OLD_EPAS_VERSION OLD_SERVICE OLD_PORT OLD_DATA OLD_TDE EPAS_VERSION NEW_SERVICE NEW_PORT NEW_DATA NEW_TDE NEW_BIN SYSTEM_USER JOBS DUMP_DIR KEEP_DUMPS

# --- BOTH CLUSTERS RUNNING, RIGHT VERSIONS ---
ensure_running "$OLD_PORT" "$OLD_SERVICE" "Old"
ensure_running "$NEW_PORT" "$NEW_SERVICE" "New"
OLD_MAJOR=$(( $(q "$OLD_PORT" postgres "SHOW server_version_num") / 10000 ))
NEW_MAJOR=$(( $(q "$NEW_PORT" postgres "SHOW server_version_num") / 10000 ))
[ "$OLD_MAJOR" = "$OLD_EPAS_VERSION" ] || die "Port ${OLD_PORT} runs version ${OLD_MAJOR}, expected OLD_EPAS_VERSION=${OLD_EPAS_VERSION}. Check OLD_PORT."
[ "$NEW_MAJOR" = "$EPAS_VERSION" ]     || die "Port ${NEW_PORT} runs version ${NEW_MAJOR}, expected EPAS_VERSION=${EPAS_VERSION}. Check PRIMARY_PORT."

# in_list NEEDLE ITEM... — exact match (no pipes: 'printf | grep -q' can fail with SIGPIPE under pipefail)
in_list() { local n="$1" x; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

# --- WHICH DATABASES ---
mapfile -t ALL_OLD_DBS < <(q "$OLD_PORT" postgres "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname")
if [ "${#SELECTED_DBS[@]}" -eq 0 ]; then
    DBS=("${ALL_OLD_DBS[@]}")
else
    DBS=()
    for d in "${SELECTED_DBS[@]}"; do
        in_list "$d" "${ALL_OLD_DBS[@]}" || die "Database '${d}' not found (or does not allow connections) on the old cluster."
        DBS+=("$d")
    done
fi
[ "${#DBS[@]}" -gt 0 ] || die "No databases to migrate."
mapfile -t NEW_DBS < <(q "$NEW_PORT" postgres "SELECT datname FROM pg_database")
exists_on_new() { in_list "$1" "${NEW_DBS[@]}"; }
sql_lit() { printf "'%s'" "${1//\'/\'\'}"; }

# objects created after initdb (OID >= 16384) and not part of an extension = user objects
USER_REL_SQL="SELECT count(*) FROM pg_class c WHERE c.oid >= 16384 AND c.relkind IN ('r','p','v','m','S','f')
  AND c.relnamespace::regnamespace::text NOT LIKE 'pg\_%'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')"
USER_FUNC_SQL="SELECT count(*) FROM pg_proc p WHERE p.oid >= 16384
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e')"

# --- NEW CLUSTER MUST NOT ALREADY HOLD THESE DATABASES ---
log_info "Checking the new cluster is empty for: ${DBS[*]}"
for d in "${DBS[@]}"; do
    exists_on_new "$d" || continue
    case "$d" in
        postgres|edb)
            n=$(q "$NEW_PORT" "$d" "$USER_REL_SQL")
            [ "$n" -eq 0 ] || die "Database '${d}' on the new cluster already has ${n} user tables/views. Restoring again would duplicate data. Use a freshly built cluster (or drop those objects) and re-run." ;;
        *)  die "Database '${d}' already exists on the new cluster. If an earlier run failed, drop it there (DROP DATABASE \"${d}\") and re-run with --db '${d}'." ;;
    esac
done

# --- EXTENSIONS USED ON OLD MUST BE INSTALLABLE ON NEW ---
mapfile -t NEW_AVAIL < <(q "$NEW_PORT" postgres "SELECT name FROM pg_available_extensions")
NEW_PRELOAD=$(q "$NEW_PORT" postgres "SHOW shared_preload_libraries")
MISSING=(); NEED_PRELOAD=()
for d in "${DBS[@]}"; do
    while IFS= read -r ext; do
        [ -n "$ext" ] || continue
        in_list "$ext" "${NEW_AVAIL[@]}" || MISSING+=("${ext} (db ${d})")
        case "$ext" in pg_cron|pgaudit)
            [[ ",${NEW_PRELOAD// /}," == *",${ext},"* ]] || NEED_PRELOAD+=("$ext") ;;
        esac
    done < <(q "$OLD_PORT" "$d" "SELECT extname FROM pg_extension ORDER BY 1")
done
[ "${#MISSING[@]}" -eq 0 ] || die "Extensions used on the old cluster are not installed for EPAS ${EPAS_VERSION}: ${MISSING[*]}. Install their EPAS ${EPAS_VERSION} packages first."
if [ "${#NEED_PRELOAD[@]}" -gt 0 ]; then
    mapfile -t NEED_PRELOAD < <(printf '%s\n' "${NEED_PRELOAD[@]}" | sort -u)
    die "Extension(s) ${NEED_PRELOAD[*]} must be in shared_preload_libraries on the new cluster (now: '${NEW_PRELOAD}'). Add them, restart ${NEW_SERVICE}, and re-run."
fi

# --- DISK SPACE: dumps (directory format, compressed) + restored data ---
DB_LIST_SQL=$(for d in "${DBS[@]}"; do sql_lit "$d"; printf ','; done); DB_LIST_SQL="${DB_LIST_SQL%,}"
SIZE_KB=$(( $(q "$OLD_PORT" postgres "SELECT COALESCE(sum(pg_database_size(datname)),0) FROM pg_database WHERE datname IN (${DB_LIST_SQL})") / 1024 ))
DUMP_PARENT=$(dirname "$DUMP_DIR")
[ -d "$DUMP_PARENT" ] || die "Parent directory of the dump dir does not exist: ${DUMP_PARENT}"
NEED_DUMP_KB=$(( SIZE_KB / 2 ))           # dumps carry no indexes and are compressed; 50 % is a safe margin
NEED_DATA_KB=$(( SIZE_KB + SIZE_KB / 10 ))
FS_DUMP=$(df -Pk "$DUMP_PARENT" | awk 'NR==2{print $1}'); FREE_DUMP=$(df -Pk "$DUMP_PARENT" | awk 'NR==2{print $4}')
FS_DATA=$(df -Pk "$NEW_DATA"    | awk 'NR==2{print $1}'); FREE_DATA=$(df -Pk "$NEW_DATA"    | awk 'NR==2{print $4}')
log_info "Databases to migrate: ${#DBS[@]}, total size on old cluster: $(( SIZE_KB / 1024 )) MB"
if [ "$FS_DUMP" = "$FS_DATA" ]; then
    [ "$FREE_DATA" -ge $(( NEED_DUMP_KB + NEED_DATA_KB )) ] || die "Not enough space on ${FS_DATA} for dumps + new data: need ~$(( (NEED_DUMP_KB + NEED_DATA_KB) / 1024 )) MB, free $(( FREE_DATA / 1024 )) MB. Use --dump-dir on another filesystem."
else
    [ "$FREE_DUMP" -ge "$NEED_DUMP_KB" ] || die "Not enough space for dumps in ${DUMP_PARENT}: need ~$(( NEED_DUMP_KB / 1024 )) MB, free $(( FREE_DUMP / 1024 )) MB. Use --dump-dir."
    [ "$FREE_DATA" -ge "$NEED_DATA_KB" ] || die "Not enough space for the restored data on ${NEW_DATA}: need ~$(( NEED_DATA_KB / 1024 )) MB, free $(( FREE_DATA / 1024 )) MB."
fi

# --- OTHER SESSIONS ON THE OLD CLUSTER ---
ACTIVE=$(q "$OLD_PORT" postgres "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND pid <> pg_backend_pid() AND datname IN (${DB_LIST_SQL})")
[ "$ACTIVE" -eq 0 ] || log_warn "${ACTIVE} other session(s) are connected to these databases on the old cluster. Changes they make during the dump will NOT be copied."
[ "$OLD_TDE" == true ] && log_warn "The old cluster is TDE-encrypted: the dump files in ${DUMP_DIR} are NOT encrypted (directory mode 700; deleted after a successful run unless --keep-dumps)."

confirm_or_exit "dump ${#DBS[@]} database(s) from port ${OLD_PORT} (EPAS ${OLD_EPAS_VERSION}) and restore them into port ${NEW_PORT} (EPAS ${EPAS_VERSION}) using ${DUMP_DIR}"

# --- DUMP DIRECTORY (700, owned by SYSTEM_USER) ---
umask 077   # dumps, logs and globals.sql (role password hashes) readable only by their owner
[ ! -e "$DUMP_DIR" ] || die "Dump directory already exists: ${DUMP_DIR} (choose another with --dump-dir)"
mkdir -p -m 700 "$DUMP_DIR"
[ "$REQUIRE_ROOT" = true ] && chown "$SYSTEM_USER" "$DUMP_DIR"
SUCCESS=false
on_exit() { [ "$SUCCESS" = true ] || log_error "Run did not complete. Dumps and logs kept in ${DUMP_DIR} - the old cluster is unchanged."; }
trap on_exit EXIT
log_audit "pgrestore upgrade started by $(whoami): ${DBS[*]} port ${OLD_PORT} -> ${NEW_PORT}, dumps in ${DUMP_DIR}"

# --- 1. GLOBALS: roles (with password hashes), tablespaces, role settings ---
log_info "Copying roles and tablespaces..."
run "$NEW_BIN/pg_dumpall" -p "$OLD_PORT" --globals-only -f "$DUMP_DIR/globals.sql"
run chmod 600 "$DUMP_DIR/globals.sql"
run "$NEW_BIN/psql" -X -q -p "$NEW_PORT" -d postgres -f "$DUMP_DIR/globals.sql" > "$DUMP_DIR/globals.log" 2>&1 || true
# "already exists" (e.g. the bootstrap superuser) is expected; anything else is reported
GLOBAL_ERRS=$(grep -iE '(^|: )error:' "$DUMP_DIR/globals.log" | grep -vc 'already exists' || true)
[ "$GLOBAL_ERRS" -eq 0 ] || log_warn "${GLOBAL_ERRS} unexpected error(s) while copying roles/tablespaces - see ${DUMP_DIR}/globals.log"

# --- 2. EACH DATABASE: dump (parallel, directory format) -> restore (parallel) ---
FAILED=()
i=0
for d in "${DBS[@]}"; do
    i=$((i + 1)); dir="$DUMP_DIR/db_${i}"; log="$DUMP_DIR/db_${i}.log"
    printf '%s\t%s\n' "db_${i}" "$d" >> "$DUMP_DIR/manifest.tsv"
    log_info "[${i}/${#DBS[@]}] ${d}: dumping (${JOBS} jobs)..."
    if ! run "$NEW_BIN/pg_dump" -p "$OLD_PORT" -d "$d" -Fd -j "$JOBS" -f "$dir" > "$log" 2>&1; then
        log_error "${d}: pg_dump failed - see ${log}"; FAILED+=("$d"); continue
    fi
    if exists_on_new "$d"; then
        # postgres / edb are created by initdb: restore into them, then copy database-level settings
        log_info "[${i}/${#DBS[@]}] ${d}: restoring into the existing database..."
        run "$NEW_BIN/pg_restore" -p "$NEW_PORT" -d "$d" -j "$JOBS" "$dir" >> "$log" 2>&1 || true
        run "$NEW_BIN/pg_dump" -p "$OLD_PORT" -d "$d" --create --schema-only --exclude-schema='*' 2>>"$log" \
            | grep -E '^(ALTER DATABASE |ALTER ROLE .* IN DATABASE |GRANT .* ON DATABASE |REVOKE .* ON DATABASE |COMMENT ON DATABASE |SECURITY LABEL .* ON DATABASE )' \
            > "$dir.dbsettings.sql" || true
        [ -s "$dir.dbsettings.sql" ] && { run "$NEW_BIN/psql" -X -q -p "$NEW_PORT" -d postgres -f "$dir.dbsettings.sql" >> "$log" 2>&1 || true; }
    else
        log_info "[${i}/${#DBS[@]}] ${d}: creating and restoring (${JOBS} jobs)..."
        run "$NEW_BIN/pg_restore" -p "$NEW_PORT" -d postgres --create -j "$JOBS" "$dir" >> "$log" 2>&1 || true
    fi
    # server errors (ERROR:) and client-tool errors (pg_dump: error:) both count; "already exists" is expected
    errs=$(grep -iE '(^|: )error:' "$log" | grep -vc 'already exists' || true)
    if [ "$errs" -gt 0 ]; then
        log_error "${d}: ${errs} error(s) during restore - see ${log}"; FAILED+=("$d")
    else
        log_info "${d}: restored."
    fi
done

# --- 3. STATISTICS (a restore carries none) ---
log_info "Rebuilding statistics: vacuumdb --analyze-in-stages ..."
for d in "${DBS[@]}"; do
    in_list "$d" "${FAILED[@]+"${FAILED[@]}"}" && continue
    run "$NEW_BIN/vacuumdb" -p "$NEW_PORT" -d "$d" --analyze-in-stages -q || log_warn "vacuumdb failed for ${d} (run it again later)"
done

# --- 4. COMPARE OBJECT COUNTS OLD vs NEW ---
log_info "Comparing user tables/views/sequences and functions (old -> new):"
MISMATCH=()
for d in "${DBS[@]}"; do
    in_list "$d" "${FAILED[@]+"${FAILED[@]}"}" && continue
    or=$(q "$OLD_PORT" "$d" "$USER_REL_SQL");  nr=$(q "$NEW_PORT" "$d" "$USER_REL_SQL")
    of=$(q "$OLD_PORT" "$d" "$USER_FUNC_SQL"); nf=$(q "$NEW_PORT" "$d" "$USER_FUNC_SQL")
    flag="OK"; { [ "$or" = "$nr" ] && [ "$of" = "$nf" ]; } || { flag="DIFFERENT"; MISMATCH+=("$d"); }
    log_info "  ${d}: relations ${or} -> ${nr}, functions ${of} -> ${nf}  ${flag}"
done

# --- SUMMARY ---
if [ "${#FAILED[@]}" -gt 0 ] || [ "${#MISMATCH[@]}" -gt 0 ]; then
    [ "${#FAILED[@]}" -eq 0 ]   || log_error "Failed: ${FAILED[*]} - fix the cause (see the db_N.log files; manifest.tsv maps db_N to names), DROP those databases on the new cluster (postgres/edb: drop the restored objects instead, or rebuild the new cluster), and re-run with --db for each."
    [ "${#MISMATCH[@]}" -eq 0 ] || log_error "Object counts differ: ${MISMATCH[*]} - check the logs before switching applications."
    log_audit "pgrestore upgrade finished WITH PROBLEMS: failed=[${FAILED[*]+"${FAILED[*]}"}] different=[${MISMATCH[*]+"${MISMATCH[*]}"}] dumps kept in ${DUMP_DIR}"
    SUCCESS=true   # the summary above already says what to do
    exit 1
fi

if [ "$KEEP_DUMPS" = false ]; then
    for ((k = 1; k <= ${#DBS[@]}; k++)); do run rm -rf "$DUMP_DIR/db_${k}" "$DUMP_DIR/db_${k}.dbsettings.sql"; done
    run rm -f "$DUMP_DIR/globals.sql"
    log_info "Dump files removed; logs kept in ${DUMP_DIR}"
else
    log_warn "Dumps kept in ${DUMP_DIR} (--keep-dumps). They contain all data and role password hashes - delete them when no longer needed."
fi
SUCCESS=true
log_audit "pgrestore upgrade completed: EPAS ${OLD_EPAS_VERSION} (port ${OLD_PORT}) -> EPAS ${EPAS_VERSION} (port ${NEW_PORT}): ${DBS[*]}"
log_info "Next: point applications at port ${NEW_PORT}, test, then stop and disable ${OLD_SERVICE} once you no longer need it."
