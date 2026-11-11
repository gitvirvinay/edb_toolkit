#!/usr/bin/env bash
# tde-openssl-to-thales-migrate.sh — move the data-key wrapping of an EXISTING TDE cluster from an openssl
# passphrase to Thales CipherTrust Manager (KMIP). The data files are not re-encrypted: only
# <datadir>/pg_encryption/key.bin is re-wrapped (EDB's documented method: old unwrap | new wrap > key.bin.new).
#
#   1. while the database runs: KMIP setup + round trip; unwrap with the CURRENT command, pipe straight into
#      Thales -> key.bin.new (the plain key never touches disk or a shell variable); verify by comparing
#      hashes of both unwrapped keys
#   2. short stop: swap key.bin, set data_encryption_key_unwrap_command; start; verify
#   3. if the start or the check fails: automatic rollback to the old key.bin + postgresql.conf, restart
# Run on EVERY node that has a copy of the cluster (primary and each standby).
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/thales-kmip.sh"

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/tde.env] [--yes]
Config: conf/tde.env by default (THALES_* = the NEW Thales key; THALES_PASS from the environment).
The current key is unwrapped with OLD_UNWRAP_CMD if set, otherwise with the server's own
data_encryption_key_unwrap_command (from postgresql.conf / postgresql.auto.conf).
If that command reads the passphrase from \$OLD_TDE_PASSPHRASE (e.g. -pass env:OLD_TDE_PASSPHRASE), export it.
Uses SRC_BINARY_DIR, DATA_TOP, PRIMARY_PORT, SERVICE_NAME, SYSTEM_USER.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown argument: $1 (see --help)" ;; esac

require_root
tde_default_env
load_env required
require_vars SRC_BINARY_DIR DATA_TOP PRIMARY_PORT SERVICE_NAME
thales_check_settings
BIN="${SRC_BINARY_DIR}/bin"
ENC_DIR="${DATA_TOP}/pg_encryption"
KEY_BIN="${ENC_DIR}/key.bin"
NEW_KEY="${ENC_DIR}/key.bin.new"
PG_CONF="${DATA_TOP}/postgresql.conf"
AUTO_CONF="${DATA_TOP}/postgresql.auto.conf"
BACKUP_DIR="$(dirname "$DATA_TOP")/tde_migrate_$(date +%Y%m%d_%H%M%S)"
[ -f "$KEY_BIN" ] || die "${KEY_BIN} not found - this cluster is not TDE-encrypted (or DATA_TOP is wrong)."
[ -f "$PG_CONF" ] || die "${PG_CONF} not found."
[ -x "${BIN}/pg_isready" ] || die "EPAS binaries not found: ${BIN}"

# --- the command the server uses today (last setting wins; auto.conf overrides postgresql.conf) ---
current_unwrap() {
    local f line val=""
    for f in "$PG_CONF" "$AUTO_CONF"; do
        [ -f "$f" ] || continue
        line=$(grep -E "^[[:space:]]*data_encryption_key_unwrap_command[[:space:]]*=" "$f" | tail -1 || true)
        [ -z "$line" ] || val="$line"
    done
    val="${val#*=}"; val="${val#"${val%%[![:space:]]*}"}"     # strip key and leading blanks
    val="${val#\'}"; val="${val%\'*}"                         # strip the surrounding quotes (and any comment after)
    printf '%s' "${val//\'\'/\'}"
}
SERVER_UNWRAP=$(current_unwrap)
case "$SERVER_UNWRAP" in *edb_tde_kmip_client*) log_info "The server already unwraps its key through KMIP. Nothing to do."; exit 0 ;; esac
for f in "$AUTO_CONF" "$DATA_TOP"/conf.d/*.conf; do
    [ -f "$f" ] || continue
    ! grep -qE "^[[:space:]]*data_encryption_key_unwrap_command" "$f" \
        || die "data_encryption_key_unwrap_command is also set in ${f}, which overrides postgresql.conf. Keep it only in postgresql.conf and re-run."
done
OLD_UNWRAP="${OLD_UNWRAP_CMD:-$SERVER_UNWRAP}"
[ -n "$OLD_UNWRAP" ] || die "No unwrap command found in ${PG_CONF} and OLD_UNWRAP_CMD not set."
[[ "$OLD_UNWRAP" == *%p* ]] || die "Old unwrap command has no %p placeholder: ${OLD_UNWRAP}"
export OLD_TDE_PASSPHRASE="${OLD_TDE_PASSPHRASE:-}"
[[ "$OLD_TDE_PASSPHRASE" != "<"* ]] || OLD_TDE_PASSPHRASE=""

OLD_UNWRAP_SHOWN=$(printf '%s' "$OLD_UNWRAP" | sed -E 's/(pass:)[^ ]+/\1********/')
show_config EPAS_VERSION SERVICE_NAME DATA_TOP PRIMARY_PORT OLD_UNWRAP_SHOWN THALES_HOST THALES_PORT THALES_USER THALES_PASS THALES_KEY_UUID DSM_DIR BACKUP_DIR
confirm_or_exit "re-wrap the TDE key of ${DATA_TOP} with Thales key ${THALES_KEY_UUID} (the database is restarted once)"

thales_install
thales_stage
thales_roundtrip

# --- 1. re-wrap into key.bin.new while the database keeps running ---
log_info "Re-wrapping the data key: old unwrap | Thales wrap -> ${NEW_KEY}"
rm -f "$NEW_KEY"
tde_run "$OLD_UNWRAP" "$KEY_BIN" | tde_run "$THALES_WRAP_CMD" "$NEW_KEY" \
    || { rm -f "$NEW_KEY"; die "Re-wrap failed (old unwrap or Thales wrap). key.bin is unchanged; check the passphrase/OLD_UNWRAP_CMD."; }
[ -s "$NEW_KEY" ] || { rm -f "$NEW_KEY"; die "Thales wrote an empty ${NEW_KEY}. key.bin is unchanged."; }
OLD_SUM=$(tde_run "$OLD_UNWRAP" "$KEY_BIN" | sha256sum | cut -d' ' -f1)
NEW_SUM=$(tde_run "$THALES_UNWRAP_CMD" "$NEW_KEY" | sha256sum | cut -d' ' -f1)
EMPTY_SUM=$(printf '' | sha256sum | cut -d' ' -f1)
if [ "$OLD_SUM" != "$NEW_SUM" ] || [ "$OLD_SUM" = "$EMPTY_SUM" ]; then
    rm -f "$NEW_KEY"; die "Verification failed: the Thales-wrapped key does not unwrap to the same data key. key.bin is unchanged."
fi
log_info "Verified: the Thales-wrapped copy unwraps to the same data key."

# --- 2. backup, stop, swap, start ---
install -d -m 0700 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$BACKUP_DIR"
cp -a "$KEY_BIN" "${BACKUP_DIR}/key.bin.openssl"
cp -a "$PG_CONF" "${BACKUP_DIR}/postgresql.conf"
log_info "Backed up key.bin and postgresql.conf to ${BACKUP_DIR}"

ready() { sudo -u "$SYSTEM_USER" "${BIN}/pg_isready" -q -p "$PRIMARY_PORT"; }
start_db() { local i; systemctl start "$SERVICE_NAME" || return 1; for ((i = 1; i <= 24; i++)); do ready && return 0; sleep 5; done; return 1; }
tde_version() { sudo -u "$SYSTEM_USER" "${BIN}/psql" -X -p "$PRIMARY_PORT" -d postgres -Atc "SELECT data_encryption_version FROM pg_control_init()" 2>/dev/null || true; }

rollback() {
    log_error "ROLLING BACK to the old key wrapping..."
    systemctl stop "$SERVICE_NAME" || true
    cp -a "${BACKUP_DIR}/key.bin.openssl" "$KEY_BIN"
    cp -a "${BACKUP_DIR}/postgresql.conf" "$PG_CONF"
    if start_db; then log_error "Rolled back: ${SERVICE_NAME} is running with the old key wrapping. The Thales copy is kept as ${NEW_KEY}.failed"
    else log_error "Rolled back the files, but ${SERVICE_NAME} still does not start - see journalctl -u ${SERVICE_NAME}"; fi
    [ ! -f "$NEW_KEY" ] || mv -f "$NEW_KEY" "${NEW_KEY}.failed"
    exit 1
}

log_info "Stopping ${SERVICE_NAME}..."
systemctl stop "$SERVICE_NAME"
! ready || die "${SERVICE_NAME} is still accepting connections after stop - aborting (nothing changed)."
mv -f "$NEW_KEY" "$KEY_BIN"                                              # old one is in BACKUP_DIR
chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$KEY_BIN"; chmod 600 "$KEY_BIN"
NEW_KEY="${BACKUP_DIR}/key.bin.thales"; cp -a "$KEY_BIN" "$NEW_KEY"       # rollback keeps a copy of it
QUOTED=${THALES_UNWRAP_CMD//\'/\'\'}
sed -i -E "s|^([[:space:]]*data_encryption_key_unwrap_command[[:space:]]*=.*)|# \1   # replaced $(date +%F) by tde-openssl-to-thales-migrate.sh|" "$PG_CONF"
printf "data_encryption_key_unwrap_command = '%s'\n" "$QUOTED" >> "$PG_CONF"
[ "$(current_unwrap)" = "$THALES_UNWRAP_CMD" ] || rollback

log_info "Starting ${SERVICE_NAME} with the Thales unwrap command..."
start_db || rollback
[ "$(tde_version)" = "1" ] || rollback

log_audit "TDE key of ${DATA_TOP} re-wrapped with Thales key ${THALES_KEY_UUID}; old wrapping kept in ${BACKUP_DIR}"
log_info "Done. ${SERVICE_NAME} runs with the key unwrapped through Thales (data_encryption_version=1)."
log_warn "Keep ${BACKUP_DIR}/key.bin.openssl AND the old passphrase: backups taken before today contain the old wrapping."
log_info "Run this script on every other node of the cluster (standbys have their own copy of key.bin)."
