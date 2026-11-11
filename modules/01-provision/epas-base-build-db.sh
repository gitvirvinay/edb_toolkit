#!/usr/bin/env bash
# =============================================================================
# epas-base-build-db.sh - Day-1 build, part B of 2 (DATABASE OS USER, no root)
#
# Run as SYSTEM_USER (e.g. enterprisedb) after epas-base-build-root.sh:
#   1. TDE passphrase file TDE_PASS_FILE (default /etc/edb/tde/<CLUSTER_NAME>.pass, mode 0400)
#   2. initdb with TDE (--data-encryption=256), pg_hba: local peer, host scram-sha-256 (never trust),
#      WAL in WAL_TOP (--waldir) when set - skipped when DATA_TOP is already a cluster
#   3. include_dir = 'conf.d' + numbered conf.d templates (never overwritten on re-run);
#      log_directory = LOG_TOP when set, else 'log' inside PGDATA
#   4. registry entry: tools/epastab.sh add  (also rewrites pg_service.conf)
#
# Every check runs BEFORE anything is changed: tag, cluster name, part A done,
# registry free, TDE commands and passphrase. A failed check leaves the host as it was.
#
# TDE passphrase (only needed when a new cluster is created), first match wins:
#   - TDE_PASS_FILE already exists (e.g. written by a vault agent or Ansible): used as is
#   - $TDE_PASSPHRASE in the environment: written to TDE_PASS_FILE
#   - interactive terminal: asked twice, hidden, then written to TDE_PASS_FILE
# The wrap/unwrap commands read the passphrase with 'openssl -pass file:<path>', so
# postgresql.conf (data_encryption_key_unwrap_command) holds only the path - never the
# passphrase - and nothing secret shows up in 'ps'. Keep a copy of the passphrase in
# your vault: without it the cluster cannot start and backups cannot be restored.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/epas-detect.sh
source "${SCRIPT_DIR}/../../lib/epas-detect.sh"
# shellcheck source=../../lib/epas-layout.sh
source "${SCRIPT_DIR}/../../lib/epas-layout.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--tag DEV|SIT|PAT|PROD] [--yes]
Day-1 build, part B (run as SYSTEM_USER, after epas-base-build-root.sh): TDE passphrase file,
initdb with TDE (skipped for an existing cluster), conf.d templates, registry entry (epastab.sh add).
  --tag   environment tag for the registry; default ENV_TAG from the config. Required (no guessing).
Settings used: EPAS_VERSION, CLUSTER_NAME (default as<version>), BINARY_TOP, DATA_TOP, WAL_TOP and
LOG_TOP (optional; empty = inside DATA_TOP), PRIMARY_PORT,
SERVICE_NAME, SYSTEM_USER, TDE_PASS_DIR (default /etc/edb/tde), TDE_PASS_FILE (default
<TDE_PASS_DIR>/<CLUSTER_NAME>.pass), optional TDE_WRAP_CMD / TDE_UNWRAP_CMD.
Passphrase for a new cluster: existing TDE_PASS_FILE, else \$TDE_PASSPHRASE, else a hidden prompt.
USAGE
    exit 0
}

parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
CLI_TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --tag)     [[ -n "${2:-}" && "${2:-}" != --* ]] || die "--tag needs a value (DEV|SIT|PAT|PROD)"; CLI_TAG="$2"; shift 2 ;;
        --tag=*)   CLI_TAG="${1#--tag=}"; shift ;;
        *)         die "Unknown option: $1 (see --help)" ;;
    esac
done

[ "$(id -u)" -ne 0 ] || die "Run this part as the database OS user, not root:  sudo -iu <SYSTEM_USER> $0 --tag <TAG>  (root steps are in epas-base-build-root.sh)"
load_env required
cd /     # config is loaded; a working directory the DB user cannot read would only make initdb print warnings

ME="$(id -un)"
CLUSTER_NAME="${CLUSTER_NAME:-as${EPAS_VERSION}}"
TAG="${CLI_TAG:-${ENV_TAG:-}}"; TAG="${TAG^^}"
TDE_PASS_DIR="${TDE_PASS_DIR:-/etc/edb/tde}"
TDE_PASS_FILE="${TDE_PASS_FILE:-${TDE_PASS_DIR}/${CLUSTER_NAME}.pass}"
EPASTAB_FILE="$(epas_registry_file)"
INITDB="${BINARY_TOP:-}/bin/initdb"
PART_A="epas-base-build-root.sh (as root)"
MIN_PASS_LEN=12

# =============================================================================
# CHECKS - nothing below changes the host until the confirmation
# =============================================================================
require_vars SYSTEM_USER BINARY_TOP DATA_TOP PRIMARY_PORT SERVICE_NAME
[[ "$ME" == "$SYSTEM_USER" ]] || die "Run as SYSTEM_USER '${SYSTEM_USER}', not '${ME}':  sudo -iu ${SYSTEM_USER} $0 ..."
[[ "$EPAS_VERSION" =~ ^[0-9]+$ ]] || die "EPAS_VERSION must be numeric"
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid SERVICE_NAME"

[[ -n "$TAG" ]] || die "No environment tag: pass --tag DEV|SIT|PAT|PROD or set ENV_TAG in ${ENV_SOURCE}. Nothing was changed."
epas_is_valid_tag "$TAG" || die "Invalid tag '${TAG}': one of ${EPAS_TAGS}"
epas_is_valid_name "$CLUSTER_NAME" || die "Invalid CLUSTER_NAME '${CLUSTER_NAME}': as<major>[_suffix], e.g. as17 or as17_rpt (lowercase, max 32)"
[[ "$CLUSTER_NAME" =~ $EPAS_NAME_RE && "${BASH_REMATCH[1]}" == "$EPAS_VERSION" ]] \
    || die "CLUSTER_NAME '${CLUSTER_NAME}' does not match EPAS_VERSION ${EPAS_VERSION}"
epas_is_valid_port "$PRIMARY_PORT" || die "Invalid PRIMARY_PORT '${PRIMARY_PORT}'"
[[ "$DATA_TOP" == /* && "$DATA_TOP" =~ ^[A-Za-z0-9._/+-]+$ && "$DATA_TOP" != *..* ]] \
    || die "Invalid DATA_TOP '${DATA_TOP}': absolute path, letters/digits and . _ - + / only"
DATA_TOP="${DATA_TOP%/}"
WAL_TOP="${WAL_TOP:-}"; WAL_TOP="${WAL_TOP%/}"
LOG_TOP="${LOG_TOP:-}"; LOG_TOP="${LOG_TOP%/}"
for v in WAL_TOP LOG_TOP; do
    [[ -z "${!v}" ]] && continue
    epas_layout_valid_path "${!v}" || die "Invalid ${v} '${!v}': absolute path, letters/digits and . _ - + / only"
    [[ -d "${!v}" ]] || die "${v} ${!v} does not exist - run ${PART_A:-epas-base-build-root.sh} first (it creates the storage folders)"
    [[ -O "${!v}" && -w "${!v}" ]] || die "${!v} is owned by $(stat -c %U "${!v}"), not ${ME} - re-run epas-base-build-root.sh"
done

# --- part A done? ---
[[ -x "$INITDB" ]] || die "${INITDB} not found - run ${PART_A} first"
[[ -d "$DATA_TOP" ]] || die "Data directory ${DATA_TOP} does not exist - run ${PART_A} first"
[[ -O "$DATA_TOP" ]] || die "${DATA_TOP} is owned by $(stat -c %U "$DATA_TOP"), not ${ME} - run ${PART_A} first"
REG_DIR="$(dirname "$EPASTAB_FILE")"
[[ -d "$REG_DIR" && -w "$REG_DIR" ]] || die "Registry directory ${REG_DIR} missing or not writable by ${ME} - run ${PART_A} first (it runs 'epastab.sh init')"

# --- registry: this cluster must fit (epastab.sh add re-checks under its lock) ---
if epas_unit_loaded "$SERVICE_NAME"; then REG_SERVICE="$SERVICE_NAME"; else REG_SERVICE="-"; fi
REG_LINE="${CLUSTER_NAME}|${EPAS_VERSION}|${DATA_TOP}|${PRIMARY_PORT}|${REG_SERVICE}|${TAG}"
REG_STATE="new"
while IFS='|' read -r r_name r_ver r_data r_port r_svc r_tag; do
    [[ -n "$r_name" ]] || continue
    if [[ "$r_name" == "$CLUSTER_NAME" ]]; then
        [[ "${r_name}|${r_ver}|${r_data}|${r_port}|${r_svc}|${r_tag}" == "$REG_LINE" ]] \
            || die "'${CLUSTER_NAME}' is already registered as ${r_ver}:${r_data}:${r_port}:${r_svc}:${r_tag} (this run: ${EPAS_VERSION}:${DATA_TOP}:${PRIMARY_PORT}:${REG_SERVICE}:${TAG}). Fix the config, or 'epastab.sh remove --name ${CLUSTER_NAME}' first."
        REG_STATE="registered"
        continue
    fi
    [[ "$(readlink -m "$r_data")" != "$(readlink -m "$DATA_TOP")" ]] || die "${DATA_TOP} is already registered as '${r_name}'"
    [[ "$r_port" != "$PRIMARY_PORT" ]] || die "Port ${PRIMARY_PORT} is already used by '${r_name}' in ${EPASTAB_FILE}"
done < <(epas_registry_entries)

# --- new cluster or existing one? ---
NEW_CLUSTER=1
if [[ -f "${DATA_TOP}/PG_VERSION" ]]; then
    NEW_CLUSTER=0
    PGV="$(tr -d '[:space:]' < "${DATA_TOP}/PG_VERSION")"
    [[ "$PGV" == "$EPAS_VERSION" ]] || die "${DATA_TOP} holds a version ${PGV} cluster, not ${EPAS_VERSION}"
elif [[ -n "$(ls -A "$DATA_TOP")" ]]; then
    die "${DATA_TOP} is not empty and not a cluster (no PG_VERSION); initdb needs an empty directory. Contents: $(ls -A "$DATA_TOP" | head -5 | tr '\n' ' ')"
fi

# --- WAL folder: must be empty for a new cluster; an existing cluster keeps its own pg_wal ---
if [[ -n "$WAL_TOP" ]]; then
    if (( NEW_CLUSTER )); then
        [[ -z "$(ls -A "$WAL_TOP")" ]] || die "WAL_TOP ${WAL_TOP} is not empty; initdb --waldir needs an empty directory. Contents: $(ls -A "$WAL_TOP" | head -5 | tr '\n' ' ')"
    else
        CUR_WAL="$(readlink -m "${DATA_TOP}/pg_wal")"
        [[ "$CUR_WAL" == "$(readlink -m "$WAL_TOP")" ]] \
            || log_warn "Existing cluster: pg_wal is ${CUR_WAL}, not WAL_TOP ${WAL_TOP} (kept as it is; moving pg_wal needs a stopped cluster)"
    fi
fi

# --- storage layout (warnings only) ---
LAYOUT_RC=0
LAYOUT_REPORT="$(epas_layout_check)" || LAYOUT_RC=$?

# --- TDE commands and passphrase (new cluster only) ---
is_placeholder() { [[ -z "${1:-}" || "$1" == CHANGEME* || "$1" == "<"* ]]; }
USE_PASS_FILE=0
PASS_SOURCE=""
NEWPASS=""
if (( NEW_CLUSTER )); then
    [[ "$TDE_PASS_FILE" == /* && "$TDE_PASS_FILE" =~ ^[A-Za-z0-9._/-]+$ && "$TDE_PASS_FILE" != *..* ]] \
        || die "Invalid TDE_PASS_FILE '${TDE_PASS_FILE}': absolute path, letters/digits and . _ - / only"
    if [[ -z "${TDE_WRAP_CMD:-}" && -z "${TDE_UNWRAP_CMD:-}" ]]; then
        TDE_WRAP_CMD="openssl enc -e -aes-128-cbc -pbkdf2 -pass file:${TDE_PASS_FILE} -out %p"
        TDE_UNWRAP_CMD="openssl enc -d -aes-128-cbc -pbkdf2 -pass file:${TDE_PASS_FILE} -in %p"
    fi
    [[ -n "${TDE_WRAP_CMD:-}" && -n "${TDE_UNWRAP_CMD:-}" ]] || die "Set both TDE_WRAP_CMD and TDE_UNWRAP_CMD, or neither (then the defaults use ${TDE_PASS_FILE})"
    for c in "$TDE_WRAP_CMD" "$TDE_UNWRAP_CMD"; do
        if [[ "$c" == *"pass:"* ]]; then
            die "The config still has the old TDE commands with '-pass pass:...'. initdb would copy the passphrase in plain text into postgresql.conf (and from there into every backup and standby). In ${ENV_SOURCE}, replace the TDE_PASSPHRASE / TDE_WRAP_CMD / TDE_UNWRAP_CMD lines with the TDE block of conf/site.env.example (it uses '-pass file:${TDE_PASS_FILE}'). Nothing was changed."
        fi
        [[ "$c" == *%p* ]] || die "TDE command must contain %p: ${c}"
    done
    if [[ "$TDE_WRAP_CMD" == *"file:${TDE_PASS_FILE}"* && "$TDE_UNWRAP_CMD" == *"file:${TDE_PASS_FILE}"* ]]; then
        USE_PASS_FILE=1
    fi

    if (( USE_PASS_FILE )); then
        PASS_DIR="$(dirname "$TDE_PASS_FILE")"
        [[ -d "$PASS_DIR" ]] || die "${PASS_DIR} does not exist - run ${PART_A} first (it creates it, owned by ${SYSTEM_USER}, mode 0700)"
        [[ -O "$PASS_DIR" && "$(stat -c %a "$PASS_DIR")" == 700 ]] \
            || die "${PASS_DIR} must be owned by ${ME} with mode 700 (now $(stat -c '%U %a' "$PASS_DIR")) - re-run ${PART_A}"
        if [[ -e "$TDE_PASS_FILE" || -L "$TDE_PASS_FILE" ]]; then
            [[ -f "$TDE_PASS_FILE" && ! -L "$TDE_PASS_FILE" && -O "$TDE_PASS_FILE" ]] \
                || die "${TDE_PASS_FILE} must be a regular file owned by ${ME}"
            case "$(stat -c %a "$TDE_PASS_FILE")" in
                400|600) ;;
                *) die "${TDE_PASS_FILE} has mode $(stat -c %a "$TDE_PASS_FILE"); only the owner may read it:  chmod 400 ${TDE_PASS_FILE}" ;;
            esac
            IFS= read -r NEWPASS < "$TDE_PASS_FILE" || true
            [[ -n "$NEWPASS" ]] || die "${TDE_PASS_FILE} is empty"
            if ! is_placeholder "${TDE_PASSPHRASE:-}" && [[ "$TDE_PASSPHRASE" != "$NEWPASS" ]]; then
                die "\$TDE_PASSPHRASE differs from the existing ${TDE_PASS_FILE}. Unset TDE_PASSPHRASE to use the file, or remove the file to use the variable."
            fi
            PASS_SOURCE="existing file ${TDE_PASS_FILE}"
        else
            if ! is_placeholder "${TDE_PASSPHRASE:-}"; then
                NEWPASS="$TDE_PASSPHRASE"
                PASS_SOURCE="\$TDE_PASSPHRASE"
            elif [[ -t 0 ]]; then
                read -r -s -p "TDE passphrase for ${CLUSTER_NAME} (min ${MIN_PASS_LEN} characters, hidden): " NEWPASS; echo
                read -r -s -p "Same passphrase again: " p2; echo
                [[ "$NEWPASS" == "$p2" ]] || die "The two passphrases differ. Nothing was changed."
                unset p2
                PASS_SOURCE="prompt"
            else
                die "No TDE passphrase: export TDE_PASSPHRASE, run interactively to be asked, or have your vault/automation write ${TDE_PASS_FILE} (owner ${SYSTEM_USER}, mode 0400). Nothing was changed."
            fi
            (( ${#NEWPASS} >= MIN_PASS_LEN )) || die "TDE passphrase too short (${#NEWPASS} characters, minimum ${MIN_PASS_LEN}). Nothing was changed."
            [[ "$NEWPASS" != *$'\n'* ]] || die "TDE passphrase must be one line. Nothing was changed."
        fi
    else
        PASS_SOURCE="custom TDE_WRAP_CMD / TDE_UNWRAP_CMD from the config"
    fi
fi

# =============================================================================
# SUMMARY & CONFIRMATION
# =============================================================================
show_config EPAS_VERSION CLUSTER_NAME TAG SYSTEM_USER BINARY_TOP DATA_TOP WAL_TOP LOG_TOP PRIMARY_PORT SERVICE_NAME
while IFS= read -r line; do
    case "$line" in
        WARN*) log_warn "Storage: ${line#WARN  }" ;;
        ?*)    log_info "Storage: ${line#OK    }" ;;
    esac
done <<< "$LAYOUT_REPORT"
(( LAYOUT_RC == 0 )) || log_warn "Storage layout is not fully separated (see above). Fine for a lab; for PAT/PROD ask for separate mounts before go-live."
log_info "  registry: ${EPASTAB_FILE} (${REG_STATE}; service column '${REG_SERVICE}')"
if (( NEW_CLUSTER )); then
    log_info "  TDE passphrase: ${PASS_SOURCE}"
    (( USE_PASS_FILE )) && log_info "  TDE passphrase file: ${TDE_PASS_FILE}"
    confirm_or_exit "create TDE cluster ${CLUSTER_NAME} in ${DATA_TOP}${WAL_TOP:+ with WAL in ${WAL_TOP}} (initdb --data-encryption=256), stage conf.d templates, register it as ${TAG}"
else
    log_info "  ${DATA_TOP} is already a version ${EPAS_VERSION} cluster: initdb and TDE steps are skipped"
    confirm_or_exit "keep the existing cluster in ${DATA_TOP}, stage missing conf.d templates, register it as ${CLUSTER_NAME} (${TAG})"
fi

log_info "START: EPAS ${EPAS_VERSION} build, part B (${ME})"

# =============================================================================
# TDE PASSPHRASE FILE + INITDB
# =============================================================================
if (( NEW_CLUSTER )); then
    if (( USE_PASS_FILE )) && [[ ! -e "$TDE_PASS_FILE" ]]; then
        # printf is a shell builtin: the passphrase never appears on a command line.
        TMP_PASS="$(umask 077; mktemp "${TDE_PASS_FILE}.XXXXXX")"
        printf '%s\n' "$NEWPASS" > "$TMP_PASS"
        chmod 0400 "$TMP_PASS"
        mv -f "$TMP_PASS" "$TDE_PASS_FILE"
        log_info "Wrote ${TDE_PASS_FILE} (mode 0400). Keep the passphrase in your vault too: without it this cluster cannot start and its backups cannot be restored."
    fi

    # Round trip: wrap a test value and unwrap it with the configured commands, before initdb.
    PROBE_DIR="$(mktemp -d)"
    trap 'rm -rf "${PROBE_DIR:-/nonexistent}"' EXIT
    PROBE_WRAP="${TDE_WRAP_CMD//%p/${PROBE_DIR}/probe.bin}"
    PROBE_UNWRAP="${TDE_UNWRAP_CMD//%p/${PROBE_DIR}/probe.bin}"
    PROBE_OUT="$(printf 'edb_toolkit-tde-probe' | sh -c "$PROBE_WRAP" && sh -c "$PROBE_UNWRAP")" || PROBE_OUT=""
    [[ "$PROBE_OUT" == "edb_toolkit-tde-probe" ]] || die "TDE wrap/unwrap test failed - initdb not run. Wrap: ${TDE_WRAP_CMD}"
    rm -rf "$PROBE_DIR"
    log_info "TDE wrap/unwrap round trip OK"

    unset TDE_PASSPHRASE
    export PGDATAKEYWRAPCMD="$TDE_WRAP_CMD"
    export PGDATAKEYUNWRAPCMD="$TDE_UNWRAP_CMD"
    log_info "Initializing Database Cluster with Native TDE Engine"
    # --auth-local/--auth-host: without them initdb writes "trust" (no password at all) into pg_hba.conf.
    # peer = local OS user must match the database user; scram-sha-256 = password over TCP.
    # --waldir: pg_wal becomes a symlink to WAL_TOP (its own mount). pg_basebackup and pg_upgrade follow it.
    INITDB_ARGS=(-D "$DATA_TOP" -E UTF8 --data-encryption=256 --auth-local=peer --auth-host=scram-sha-256)
    [[ -n "$WAL_TOP" ]] && INITDB_ARGS+=(--waldir="$WAL_TOP")
    "$INITDB" "${INITDB_ARGS[@]}"
    unset PGDATAKEYWRAPCMD PGDATAKEYUNWRAPCMD

    # The passphrase must not have ended up in postgresql.conf (compared in the shell: no command line).
    if [[ -n "$NEWPASS" ]]; then
        CONF_TEXT="$(cat "${DATA_TOP}/postgresql.conf" "${DATA_TOP}/postgresql.auto.conf" 2>/dev/null || true)"
        if [[ "$CONF_TEXT" == *"$NEWPASS"* ]]; then
            die "The TDE passphrase appears in plain text in ${DATA_TOP}/postgresql*.conf - check the unwrap command before starting or backing up this cluster"
        fi
        unset CONF_TEXT
    fi
    log_info "Unwrap command stored in postgresql.conf: $(grep -E '^[[:space:]]*data_encryption_key_unwrap_command' "${DATA_TOP}/postgresql.conf" | tail -1 || echo '(not found)')"
else
    log_info "Existing cluster in ${DATA_TOP} (TDE: $(epas_tde "$DATA_TOP" 2>/dev/null || echo unknown)) - initdb skipped"
fi
NEWPASS=""

# =============================================================================
# CONFIGURATION INJECTION
# =============================================================================
mkdir -p "${DATA_TOP}/conf.d"
PG_CONF="${DATA_TOP}/postgresql.conf"
if ! grep -q "include_dir = 'conf.d'" "$PG_CONF"; then
    echo "include_dir = 'conf.d'" >> "$PG_CONF"
fi

# -----------------------------------------------------------------------------
# CONF.D TEMPLATE STAGING
#
# Templates are dropped into conf.d/ ONLY if absent - local/site edits are
# never overwritten on re-run. conf.d files load in C-string sort order, so
# numbering controls precedence:
#
#   01-network.conf       connectivity / port / max_connections
#   02-memory.conf        memory sizing (auto-tuned to host RAM at build time)
#   03-logging.conf       logging collector & rotation
#   04-extensions.conf    shared_preload_libraries + per-extension settings
#   05-compatibility.conf EPAS/Oracle compatibility switches
#   99-local.conf         LAST template slot for site-specific overrides
#
# (epas-ssl-setup.sh later adds 'ssl.conf'; alphabetically 'ssl.conf' sorts
#  AFTER '99-local.conf', so SSL knobs always win.)
# -----------------------------------------------------------------------------

# Server logs: LOG_TOP (own mount) when set, else the old layout 'log' inside PGDATA.
if [[ -n "$LOG_TOP" ]]; then LOG_DIRECTORY="$LOG_TOP"; else LOG_DIRECTORY="log"; fi

TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
SHARED_BUFFERS_MB=$(( TOTAL_MEM_KB / 4 / 1024 ))              # 25% of RAM
EFFECTIVE_CACHE_MB=$(( TOTAL_MEM_KB * 3 / 4 / 1024 ))         # 75% of RAM
MAINT_WORK_MEM_MB=$(( TOTAL_MEM_KB / 16 / 1024 ))
[[ $MAINT_WORK_MEM_MB -gt 2048 ]] && MAINT_WORK_MEM_MB=2048   # cap 2GB
WORK_MEM_MB=$(( TOTAL_MEM_KB / 1024 / 400 ))
[[ $WORK_MEM_MB -lt 4 ]] && WORK_MEM_MB=4
[[ $WORK_MEM_MB -gt 64 ]] && WORK_MEM_MB=64

log_info "Pre-staging conf.d templates (shared_buffers=${SHARED_BUFFERS_MB}MB, effective_cache=${EFFECTIVE_CACHE_MB}MB)"

# stage_template <filename> : reads template content from STDIN.
# Never overwrites an existing file in conf.d.
stage_template() {
    local target="${DATA_TOP}/conf.d/$1"
    if [[ -f "$target" ]]; then
        log_info "conf.d/$1 already exists - keeping local version"
        cat > /dev/null
    else
        cat > "$target"
        log_info "Staged conf.d/$1"
    fi
}

# ---- 01-network.conf ---------------------------------------------------------
stage_template "01-network.conf" <<EOF
# Connectivity & network sizing
# Managed by epas-base-build - edit freely; never overwritten on re-run.
port = ${PRIMARY_PORT}
listen_addresses = '*'
max_connections = 300
superuser_reserved_connections = 10
tcp_keepalives_idle = 600
tcp_keepalives_interval = 30
tcp_keepalives_count = 3
EOF

# ---- 02-memory.conf ----------------------------------------------------------
stage_template "02-memory.conf" <<EOF
# Memory sizing - auto-tuned at build time ($(date +%F)) for ${TOTAL_MEM_KB} kB RAM
# Managed by epas-base-build - edit freely; never overwritten on re-run.
shared_buffers = ${SHARED_BUFFERS_MB}MB
huge_pages = try
effective_cache_size = ${EFFECTIVE_CACHE_MB}MB
maintenance_work_mem = ${MAINT_WORK_MEM_MB}MB
work_mem = ${WORK_MEM_MB}MB
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
random_page_cost = 1.1
EOF

# ---- 03-logging.conf ---------------------------------------------------------
stage_template "03-logging.conf" <<EOF
# Logging collector, rotation & statement logging
# Managed by epas-base-build - edit freely; never overwritten on re-run.
logging_collector = on
log_destination = 'stderr'
log_directory = '${LOG_DIRECTORY}'
log_filename = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_rotation_size = 0
log_min_duration_statement = 1000
log_statement = 'ddl'
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_autovacuum_min_duration = 0
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'UTC'
EOF

# ---- 04-extensions.conf ------------------------------------------------------
# \$libdir is escaped so it reaches the file literally; ${EPAS_VERSION} is expanded.
stage_template "04-extensions.conf" <<EOF
# Extension framework: preload list + per-extension settings
# Managed by epas-base-build - edit freely; never overwritten on re-run.
# WARNING: every module in shared_preload_libraries MUST be installed
#          or the server will refuse to start (see pgaudit / pg_cron notes).

shared_preload_libraries = '\$libdir/dbms_pipe,\$libdir/edb_gen,\$libdir/dbms_aq,\$libdir/sql-profiler,\$libdir/edb_filter_log,edb_wait_states,edb_stat_monitor,query_advisor,pg_stat_statements,auto_explain'

# edb_wait_states
edb_wait_states.retention_period = 7776000   # 90 days

# pg_stat_statements
pg_stat_statements.track = all
pg_stat_statements.max = 10000

# pgaudit (requires edb-pg${EPAS_VERSION}-pgaudit package)
pgaudit.log = 'write,ddl'
pgaudit.log_catalog = off

# pg_cron (requires edb-pg${EPAS_VERSION}-pg-cron package)
pg_cron.database_name = 'edb'

# auto_explain
auto_explain.log_min_duration = '5s'
auto_explain.log_analyze = on
auto_explain.log_buffers = on
EOF

# ---- 05-compatibility.conf ---------------------------------------------------
stage_template "05-compatibility.conf" <<'EOF'
# EPAS / Oracle-mode compatibility switches
# Managed by epas-base-build - edit freely; never overwritten on re-run.
edb_redwood_strings = on
edb_redwood_date = on
edb_redwood_greatest_least = on
edb_dynatune = on
edb_dynatune_profile = oltp
search_path = '"$user", public, sys, dbo'
standard_conforming_strings = on
EOF

# ---- 99-local.conf -----------------------------------------------------------
stage_template "99-local.conf" <<'EOF'
# 99-local.conf - site-specific overrides (loaded after all numbered templates)
# Managed by epas-base-build - edit freely; never overwritten on re-run.
# Put anything that must override the numbered templates here, e.g.:
#   shared_buffers = 64GB
#   log_min_duration_statement = 500
EOF

# =============================================================================
# CLUSTER REGISTRY (also rewrites /etc/edb/toolkit/pg_service.conf)
# =============================================================================
"${TOOLKIT_ROOT}/tools/epastab.sh" add --name "$CLUSTER_NAME" --version "$EPAS_VERSION" \
    --data "$DATA_TOP" --port "$PRIMARY_PORT" --service "$REG_SERVICE" --tag "$TAG"

log_audit "Day 1 part B done: ${CLUSTER_NAME} (${TAG}) EPAS ${EPAS_VERSION}, data ${DATA_TOP}, port ${PRIMARY_PORT}, TDE $( (( NEW_CLUSTER )) && echo "new, ${PASS_SOURCE}" || echo "existing cluster kept")"

log_info "Next: start the cluster"
if [[ "$REG_SERVICE" != "-" ]]; then
    log_info "  sudo systemctl start ${SERVICE_NAME}    (allowed for ${SYSTEM_USER} by conf/sudoers.d/epas-automation)"
else
    log_info "  ${BINARY_TOP}/bin/pg_ctl -D ${DATA_TOP} -l ${LOG_TOP:-${DATA_TOP}/log}/startup.log start"
fi
log_info "  then:  . epasenv ${CLUSTER_NAME}   and   psql service=${CLUSTER_NAME}"
