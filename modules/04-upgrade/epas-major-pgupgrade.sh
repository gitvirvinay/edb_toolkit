#!/usr/bin/env bash
# epas-major-pgupgrade.sh — major version upgrade with pg_upgrade (copy or --link mode).
# The NEW cluster must already exist (built with 01-provision/epas-base-build.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

USE_LINK=false
REQUIRE_ROOT=false

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--link] [--root] [--yes]
Upgrades OLD_DATA_TOP (EPAS OLD_EPAS_VERSION) into the already-initialised DATA_TOP (EPAS EPAS_VERSION):
pg_upgrade --check, stop both services, pg_upgrade, start the new service, rebuild statistics.
  --link : pg_upgrade hard links (fast, no extra disk; the old cluster is unusable once the new one starts).
           Refused when either cluster uses TDE.
TDE clusters are upgraded with --copy-by-block automatically (data re-encrypted with the new cluster's key).
  --root : run as root (pg_upgrade runs via 'sudo -u SYSTEM_USER'); otherwise run as SYSTEM_USER.
  --yes  : skip the confirmation questions (including "verified backup taken?").
Config is required (default conf/site.env): OLD_EPAS_VERSION, OLD_DATA_TOP, OLD_SRC_BINARY_DIR,
OLD_SERVICE_NAME, EPAS_VERSION, DATA_TOP, SRC_BINARY_DIR, SERVICE_NAME, SYSTEM_USER, PRIMARY_PORT,
and for TDE: TDE_WRAP_CMD / TDE_UNWRAP_CMD (or you are asked for the passphrase).
USAGE
    exit 0
}

parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --link)    USE_LINK=true; shift ;;
        --root)    REQUIRE_ROOT=true; shift ;;
        -h|--help) usage ;;
        *)         die "Unknown argument: $1 (see --help)" ;;
    esac
done

# --- CONFIG (old cluster + new cluster) ---
load_env required
require_vars OLD_EPAS_VERSION OLD_DATA_TOP EPAS_VERSION DATA_TOP SRC_BINARY_DIR SYSTEM_USER PRIMARY_PORT
OLD_SERVICE="${OLD_SERVICE_NAME:-edb-as-${OLD_EPAS_VERSION}}"
OLD_BIN="${OLD_SRC_BINARY_DIR:-/usr/edb/as${OLD_EPAS_VERSION}}/bin"
OLD_DATA="${OLD_DATA_TOP}"
NEW_SERVICE="${SERVICE_NAME}"
NEW_BIN="${SRC_BINARY_DIR}/bin"
NEW_DATA="${DATA_TOP}"            # DATA_TOP is the data directory itself (was wrongly "${DATA_TOP}/data")
EXPECTED_USER="${SYSTEM_USER}"

[[ "$OLD_EPAS_VERSION" =~ ^[0-9]+$ && "$OLD_EPAS_VERSION" -lt "$EPAS_VERSION" ]] \
    || die "OLD_EPAS_VERSION (${OLD_EPAS_VERSION}) must be lower than EPAS_VERSION (${EPAS_VERSION})."
[[ -x "$NEW_BIN/pg_upgrade" ]] || die "pg_upgrade not found: $NEW_BIN/pg_upgrade"
[[ -x "$OLD_BIN/pg_ctl" ]]     || die "Old binaries not found: $OLD_BIN"
[[ -f "$OLD_DATA/PG_VERSION" ]] || die "Old cluster not found: $OLD_DATA/PG_VERSION"
[[ -f "$NEW_DATA/PG_VERSION" ]] || die "New cluster not initialised: $NEW_DATA/PG_VERSION (build it first with 01-provision/epas-base-build.sh)"

# --- TDE detection: the wrapped key lives in <datadir>/pg_encryption/key.bin ---
OLD_TDE=false; [[ -f "$OLD_DATA/pg_encryption/key.bin" ]] && OLD_TDE=true
NEW_TDE=false; [[ -f "$NEW_DATA/pg_encryption/key.bin" ]] && NEW_TDE=true
if [[ "$USE_LINK" == true && ( "$OLD_TDE" == true || "$NEW_TDE" == true ) ]]; then
    die "--link is not supported for TDE-encrypted clusters (old TDE=${OLD_TDE}, new TDE=${NEW_TDE}). Run without --link (copy mode)."
fi

# --- USER CONTEXT CHECK ---
CURRENT_USER=$(whoami)
if [ "$REQUIRE_ROOT" = true ]; then
    require_root
    EXEC_CMD="sudo -u ${EXPECTED_USER}"
else
    [ "$CURRENT_USER" != "root" ] || die "Do not run as root without --root. Execute as '${EXPECTED_USER}' or pass --root."
    [ "$CURRENT_USER" == "$EXPECTED_USER" ] || die "Script must be executed as '${EXPECTED_USER}' (currently: ${CURRENT_USER})."
    EXEC_CMD=""
fi

MODE_STR=$([ "$USE_LINK" = true ] && echo "link" || { [[ "$OLD_TDE" == true || "$NEW_TDE" == true ]] && echo "copy-by-block" || echo "copy"; })
show_config OLD_EPAS_VERSION OLD_SERVICE OLD_BIN OLD_DATA OLD_TDE EPAS_VERSION NEW_SERVICE NEW_BIN NEW_DATA NEW_TDE EXPECTED_USER MODE_STR

# --- DISK SPACE CHECK (COPY MODE ONLY) ---
if [ "$USE_LINK" = false ]; then
    log_info "Verifying disk space allocation for copy-mode upgrade..."
    OLD_DATA_SIZE_KB=$(du -s "$OLD_DATA" | awk '{print $1}')
    NEW_DATA_DIR=$(dirname "$NEW_DATA")
    FREE_SPACE_KB=$(df -k "$NEW_DATA_DIR" | awk 'NR==2 {print $4}')
    REQUIRED_SPACE_KB=$(( OLD_DATA_SIZE_KB + (OLD_DATA_SIZE_KB / 10) ))
    if [ "$FREE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
        log_error "Insufficient disk space on ${NEW_DATA_DIR}."
        log_error "Required: ~$(( REQUIRED_SPACE_KB / 1024 )) MB | Free: $(( FREE_SPACE_KB / 1024 )) MB"
        die "Aborting: Copy-based upgrade requires enough space for both clusters."
    fi
else
    log_info "Link mode enabled (--link): Skipping strict disk copy space validation."
fi

# --- BACKUP CONFIRMATION ---
if [[ "$ASSUME_YES" == "1" ]]; then
    log_audit "Backup confirmation for ${OLD_DATA} given via --yes by $(whoami)"
else
    read -r -p "Have you taken a verified filesystem-level backup of ${OLD_DATA}? (yes/NO): " BACKUP_CONFIRM
    [[ "$BACKUP_CONFIRM" == "yes" ]] || die "Aborting -- verified backup required before major migration."
fi

# --- TDE KEY COMMANDS ---
if [[ -n "${TDE_WRAP_CMD:-}" && -n "${TDE_UNWRAP_CMD:-}" && "${TDE_WRAP_CMD}" != *CHANGEME* ]]; then
    log_info "Using TDE Key Wrap/Unwrap commands defined in the config"
    export PGDATAKEYWRAPCMD="${TDE_WRAP_CMD}"
    export PGDATAKEYUNWRAPCMD="${TDE_UNWRAP_CMD}"
else
    read -r -s -p "Enter TDE master passphrase: " PGPASSWORD_TDE; echo ""
    TMP_PASS=$(mktemp)
    chmod 600 "$TMP_PASS"
    printf '%s' "$PGPASSWORD_TDE" > "$TMP_PASS"
    # pg_upgrade runs as EXPECTED_USER (via sudo in --root mode): it must be able to read the file
    [ "$REQUIRE_ROOT" = true ] && chown "$EXPECTED_USER" "$TMP_PASS"
    export PGDATAKEYWRAPCMD="openssl enc -e -aes-128-cbc -pbkdf2 -pass file:${TMP_PASS} -out %p"
    export PGDATAKEYUNWRAPCMD="openssl enc -d -aes-128-cbc -pbkdf2 -pass file:${TMP_PASS} -in %p"
    cleanup() { [ -f "${TMP_PASS:-}" ] && { shred -u "$TMP_PASS" 2>/dev/null || rm -f "$TMP_PASS"; }; }
    trap cleanup EXIT INT TERM HUP
fi

# pg_upgrade writes its logs to the current directory
cd /tmp

UPGRADE_ARGS=(
    "--old-datadir=$OLD_DATA"
    "--new-datadir=$NEW_DATA"
    "--old-bindir=$OLD_BIN"
    "--new-bindir=$NEW_BIN"
)
[ "$USE_LINK" = true ] && UPGRADE_ARGS+=("--link")
# TDE: the new cluster built by epas-base-build.sh has its OWN data key, so pg_upgrade must decrypt
# with the old key and re-encrypt with the new one block by block (EDB docs: --copy-by-block is
# required when old/new clusters have different encryption settings or keys). Slower than a plain copy.
if [[ "$OLD_TDE" == true || "$NEW_TDE" == true ]]; then
    UPGRADE_ARGS+=("--copy-by-block")
    log_info "TDE detected (old=${OLD_TDE}, new=${NEW_TDE}): using --copy-by-block (decrypt + re-encrypt; slower than a plain copy)."
fi

systemctl_cmd() { if [ "$REQUIRE_ROOT" = true ]; then systemctl "$@"; else sudo systemctl "$@"; fi; }

# --- PREFLIGHT RUN (CHECK MODE) ---
log_info "Executing structural compatibility preflight analysis..."
$EXEC_CMD env PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" "${UPGRADE_ARGS[@]}" --check

confirm_or_exit "preflight passed - stop ${OLD_SERVICE} and ${NEW_SERVICE} and run the ${MODE_STR}-mode upgrade ${OLD_DATA} -> ${NEW_DATA}"

# --- SERVICE CONTROL ---
log_info "Stopping database services..."
systemctl_cmd stop "$OLD_SERVICE" || true
systemctl_cmd stop "$NEW_SERVICE" || true

# --- ACTUAL UPGRADE RUN ---
log_info "Starting database upgrade..."
if ! $EXEC_CMD env PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
        "$NEW_BIN/pg_upgrade" "${UPGRADE_ARGS[@]}"; then
    log_error "pg_upgrade FAILED. Both services are stopped. pg_upgrade logs: /tmp/ and ${NEW_DATA}/pg_upgrade_output.d"
    if [ "$USE_LINK" = true ]; then
        die "Link mode: if the failure happened before the linking step the old cluster is intact - check the log, then 'systemctl start ${OLD_SERVICE}'. Do NOT start ${NEW_SERVICE}."
    fi
    die "Copy mode: the old cluster is untouched - bring it back with: systemctl start ${OLD_SERVICE}"
fi

# --- START NEW SERVICE ---
log_info "Starting new database service (${NEW_SERVICE})..."
systemctl_cmd start "$NEW_SERVICE"
wait_for_epas 24 5 || die "${NEW_SERVICE} did not accept connections on port ${PRIMARY_PORT}. Check: journalctl -u ${NEW_SERVICE}"

# --- POST-UPGRADE STATISTICS ---
# pg_upgrade 14+ no longer writes analyze_new_cluster.sh; the documented replacement is vacuumdb.
ANALYZE_SCRIPT="${SCRIPT_DIR}/analyze_new_cluster.sh"
if [ -f "/tmp/analyze_new_cluster.sh" ]; then
    log_info "Rebuilding statistics (analyze_new_cluster.sh)..."
    $EXEC_CMD bash /tmp/analyze_new_cluster.sh
elif [ -f "$ANALYZE_SCRIPT" ]; then
    log_info "Rebuilding statistics (analyze_new_cluster.sh)..."
    $EXEC_CMD bash "$ANALYZE_SCRIPT"
else
    log_info "Rebuilding statistics: vacuumdb --all --analyze-in-stages ..."
    $EXEC_CMD "$NEW_BIN/vacuumdb" -p "$PRIMARY_PORT" --all --analyze-in-stages
fi

log_audit "Major upgrade completed (${MODE_STR}-mode): EPAS ${OLD_EPAS_VERSION} ${OLD_DATA} -> EPAS ${EPAS_VERSION} ${NEW_DATA}"
log_info "Next: check the application, then remove the old cluster with /tmp/delete_old_cluster.sh (if generated) once you no longer need it."
