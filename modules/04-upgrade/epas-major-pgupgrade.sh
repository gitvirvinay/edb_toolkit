#!/usr/bin/env bash
# epas-major-pgupgrade.sh — major version upgrade with pg_upgrade (copy or --link mode).
# The NEW cluster must already exist (built with 01-provision/epas-base-build-root.sh + epas-base-build-db.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/epas-detect.sh
source "${SCRIPT_DIR}/../../lib/epas-detect.sh"
# shellcheck source=../../lib/epas-tde.sh
source "${SCRIPT_DIR}/../../lib/epas-tde.sh"
MIGRATE_SSL="${SCRIPT_DIR}/../02-ssl/epas-migrate-ssl-conf.sh"

USE_LINK=false
REQUIRE_ROOT=false

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--link] [--root] [--yes]
Upgrades OLD_DATA_TOP (EPAS OLD_EPAS_VERSION) into the already-initialised DATA_TOP (EPAS EPAS_VERSION):
pg_upgrade --check, stop both services, pg_upgrade, carry pg_hba.conf / pg_ident.conf / SSL settings
(pg_upgrade copies no config files), start the new service, check SSL, rebuild statistics.
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
[[ -f "$NEW_DATA/PG_VERSION" ]] || die "New cluster not initialised: $NEW_DATA/PG_VERSION (build it first with 01-provision/epas-base-build-root.sh + epas-base-build-db.sh)"

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

# --- EFM GUARD: this script stops the old and new EPAS services. Under a running EFM agent that looks
#     like a database failure and can cause a failover in the middle of the upgrade. Stop the EFM
#     agents of the whole cluster first (primary, standby and witness), as you did for 14 to 17. ---
EFM_AGENTS="$(efm_agents_running)"
[ -z "$EFM_AGENTS" ] || die "An EFM agent is running on this host (${EFM_AGENTS}). Stop EFM on every node of this cluster before the upgrade, so EFM cannot fail over while EPAS is stopped. Nothing was changed."

# --- CONNECTION CONFIG: pg_upgrade copies no config files, so the old pg_hba.conf / pg_ident.conf and
#     SSL settings are carried after pg_upgrade. Checked NOW, before anything is stopped. ---
OLD_SSL_ON=false
case "$(epas_conf_get "$OLD_DATA" ssl)" in [Oo][Nn]|[Tt]rue|[Yy]es|1) OLD_SSL_ON=true ;; esac
HBA_CUSTOM="$(epas_conf_get "$OLD_DATA" hba_file)$(epas_conf_get "$OLD_DATA" ident_file)"
if [[ -n "$HBA_CUSTOM" ]]; then
    log_warn "The old cluster sets hba_file/ident_file explicitly - pg_hba.conf/pg_ident.conf are NOT carried; review the new cluster's by hand."
fi
MIGRATE_ENV=(); [[ -n "${ENV_SOURCE:-}" ]] && MIGRATE_ENV=(--env "$(readlink -f "$ENV_SOURCE")")
log_info "Checking that the old cluster's SSL settings can be carried over..."
$EXEC_CMD bash "$MIGRATE_SSL" "${MIGRATE_ENV[@]+"${MIGRATE_ENV[@]}"}" --old "$OLD_DATA" --new "$NEW_DATA" --check \
    || die "The old cluster's SSL settings cannot be carried to the new cluster (see above). Nothing was changed."

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
    # --- TDE PREFLIGHT (nothing is stopped yet). pg_upgrade gets ONE unwrap command for both clusters,
    #     so the old and the new cluster must use the same passphrase. ---
    if [[ "$OLD_TDE" == true || "$NEW_TDE" == true ]]; then
        tde_report() {   # tde_report TEXT: log OK/WARN/ERROR lines; returns 1 if any ERROR
            local line rc=0
            while IFS= read -r line; do
                case "$line" in
                    ERROR*) log_error "TDE: ${line#ERROR }"; rc=1 ;;
                    WARN*)  log_warn  "TDE: ${line#WARN  }" ;;
                    ?*)     log_info  "TDE: ${line#OK    }" ;;
                esac
            done <<< "$1"
            return "$rc"
        }
        TDE_FILE_NEW="$(epas_tde_passfile "$TDE_UNWRAP_CMD")"
        TDE_REPORT="$(epas_tde_check_unwrap "$TDE_UNWRAP_CMD" "$NEW_DATA")" || true
        tde_report "$TDE_REPORT" || die "TDE_UNWRAP_CMD does not pass the checks above. Nothing was changed."
        # The file must not live in the OLD data directory either: removing the old cluster after sign-off would take it.
        if [[ -n "$TDE_FILE_NEW" ]]; then
            case "$(readlink -m "$TDE_FILE_NEW")/" in
                "$(readlink -m "$OLD_DATA")"/*) die "The passphrase file ${TDE_FILE_NEW} is inside the old data directory ${OLD_DATA}. Move it to /etc/edb/tde first. Nothing was changed." ;;
            esac
        fi
        # What does the OLD cluster use? Its own postgresql.conf says.
        OLD_UNWRAP="$(epas_conf_get "$OLD_DATA" data_encryption_key_unwrap_command)"
        if [[ -z "$OLD_UNWRAP" ]]; then
            log_warn "TDE: the old cluster's postgresql.conf has no data_encryption_key_unwrap_command (set another way?): cannot compare its passphrase with the new one."
        else
            if [[ "$OLD_UNWRAP" =~ -pass[[:space:]]+[\"\']?pass: ]]; then
                log_warn "TDE: the old cluster's unwrap command holds its passphrase in plain text in postgresql.conf. Fix this on the new cluster (use -pass file:); the old cluster goes away after sign-off."
            fi
            TDE_FILE_OLD="$(epas_tde_passfile "$OLD_UNWRAP")"
            if [[ -n "$TDE_FILE_OLD" && -n "$TDE_FILE_NEW" ]]; then
                SAME_RC=0; epas_tde_same_passphrase "$TDE_FILE_OLD" "$TDE_FILE_NEW" || SAME_RC=$?
                case "$SAME_RC" in
                    0) log_info "TDE: the old and new passphrase files hold the same passphrase (as expected for one unwrap command)." ;;
                    1) die "TDE: the old cluster (${TDE_FILE_OLD}) and the new one (${TDE_FILE_NEW}) use DIFFERENT passphrases. This script gives pg_upgrade one unwrap command for both, so it cannot read both. Re-wrap the new cluster with the old passphrase, or ask for a two-command upgrade. Nothing was changed." ;;
                    *) log_warn "TDE: could not compare the old and new passphrase files (not readable by $(whoami)); pg_upgrade --check below will show if the key cannot be read." ;;
                esac
            else
                log_warn "TDE: the old or new unwrap command does not name a passphrase file: passphrases not compared; pg_upgrade --check below will show if the key cannot be read."
            fi
        fi
    fi
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
# TDE: the new cluster built by epas-base-build-db.sh has its OWN data key, so pg_upgrade must decrypt
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

# --- CARRY CONNECTION CONFIG (new cluster still stopped) ---
if [[ -z "$HBA_CUSTOM" ]]; then
    for f in pg_hba.conf pg_ident.conf; do
        [[ -f "$OLD_DATA/$f" ]] || continue
        [[ ! -L "$NEW_DATA/$f" ]] || die "Refusing to write through a symbolic link: $NEW_DATA/$f"
        [[ -f "$NEW_DATA/$f" ]] && $EXEC_CMD cp -p "$NEW_DATA/$f" "$NEW_DATA/$f.before-upgrade"
        $EXEC_CMD cp -p "$OLD_DATA/$f" "$NEW_DATA/$f"
        log_info "Carried $f from the old cluster (the new cluster's own copy: $NEW_DATA/$f.before-upgrade)"
    done
fi
$EXEC_CMD bash "$MIGRATE_SSL" "${MIGRATE_ENV[@]+"${MIGRATE_ENV[@]}"}" --old "$OLD_DATA" --new "$NEW_DATA" --yes \
    || die "pg_upgrade finished, but the SSL settings were not carried - the new cluster is NOT started. Fix it (epas-migrate-ssl-conf.sh --old $OLD_DATA --new $NEW_DATA), then: systemctl start ${NEW_SERVICE}"

# --- START NEW SERVICE ---
log_info "Starting new database service (${NEW_SERVICE})..."
systemctl_cmd start "$NEW_SERVICE"
wait_for_epas 24 5 || die "${NEW_SERVICE} did not accept connections on port ${PRIMARY_PORT}. Check: journalctl -u ${NEW_SERVICE}"

# --- SSL CHECK: the new cluster must serve SSL if the old one did ---
if [[ "$OLD_SSL_ON" == true ]]; then
    NEW_SSL=$($EXEC_CMD "$NEW_BIN/psql" -X -p "$PRIMARY_PORT" -d postgres -Atc "SHOW ssl;" 2>/dev/null || true)
    if [[ "$NEW_SSL" == "on" ]]; then
        log_info "SSL is on in the new cluster, as in the old one"
    else
        log_warn "The old cluster had SSL on, the new one reports ssl = '${NEW_SSL:-unknown}' - clients requiring SSL will fail. Check ${NEW_DATA}/conf.d/ssl.conf and the server log."
    fi
fi

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
log_info "EFM cluster? Follow docs/epas-major-upgrade-efm.md: point EFM at the new cluster (05-efm/efm-reconfigure-after-upgrade.sh), start it on this node, rebuild the standby, then add it to EFM."
