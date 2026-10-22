#!/usr/bin/env bash
# tde-thales-setup.sh — create a NEW TDE-encrypted EPAS cluster whose data key is wrapped by
# Thales CipherTrust Manager (KMIP). Run it INSTEAD of the initdb step of 01-provision/epas-base-build.sh:
#   1. this script   (KMIP client, certificates, round-trip test, initdb with Thales, start/verify/stop)
#   2. 01-provision/epas-base-build.sh   (sees the existing cluster, skips initdb, does systemd + conf.d)
# For an existing passphrase-wrapped cluster use tde-openssl-to-thales-migrate.sh instead.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"
source "${SCRIPT_DIR}/thales-kmip.sh"

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/tde.env] [--yes]
Config: conf/tde.env by default (loads conf/site.env, adds THALES_* and DSM_DIR). THALES_PASS should come from
the environment / secrets manager. Uses SRC_BINARY_DIR, DATA_TOP, PRIMARY_PORT, SYSTEM_USER, SYSTEM_GROUP.
Stops before initdb if Thales can't encrypt and decrypt a test value.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown argument: $1 (see --help)" ;; esac

require_root
tde_default_env
load_env required
require_vars SRC_BINARY_DIR DATA_TOP PRIMARY_PORT
thales_check_settings
BIN="${SRC_BINARY_DIR}/bin"
[ -x "${BIN}/initdb" ] || die "EPAS binaries not found: ${BIN}/initdb (install EPAS ${EPAS_VERSION} first)"

# --- existing cluster? ---
if [ -f "${DATA_TOP}/PG_VERSION" ]; then
    if [ -f "${DATA_TOP}/pg_encryption/key.bin" ]; then
        UNWRAP_NOW=$(grep -E "^[[:space:]]*data_encryption_key_unwrap_command" "${DATA_TOP}/postgresql.conf" | tail -1 || true)
        case "$UNWRAP_NOW" in
            *edb_tde_kmip_client*) log_info "Cluster in ${DATA_TOP} is already TDE-encrypted with a KMIP-wrapped key. Nothing to do."; exit 0 ;;
            *) die "Cluster in ${DATA_TOP} is already TDE-encrypted with a different key wrapping. To move its key to Thales, use tde-openssl-to-thales-migrate.sh." ;;
        esac
    fi
    die "Cluster in ${DATA_TOP} exists WITHOUT TDE. TDE is chosen at initdb; to encrypt existing data, build a new TDE cluster and move the data with 04-upgrade (pg_upgrade --copy-by-block or dump/restore)."
fi
[ -z "$(ls -A "$DATA_TOP" 2>/dev/null)" ] || die "${DATA_TOP} is not empty but has no cluster in it - check it by hand."

show_config EPAS_VERSION BIN DATA_TOP PRIMARY_PORT SYSTEM_USER THALES_HOST THALES_PORT THALES_USER THALES_PASS THALES_KEY_UUID DSM_DIR
confirm_or_exit "install the KMIP client, stage Thales certificates in ${DSM_DIR} and initdb a TDE cluster in ${DATA_TOP}"

thales_install
thales_stage
thales_roundtrip

# --- initdb with the Thales wrap/unwrap commands (initdb records the unwrap command in postgresql.conf) ---
log_info "initdb --data-encryption=256 in ${DATA_TOP}..."
install -d -m 0700 -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" "$DATA_TOP"
sudo -u "$SYSTEM_USER" env PGDATAKEYWRAPCMD="$THALES_WRAP_CMD" PGDATAKEYUNWRAPCMD="$THALES_UNWRAP_CMD" \
    "${BIN}/initdb" -D "$DATA_TOP" -E UTF8 --data-encryption=256
[ -f "${DATA_TOP}/pg_encryption/key.bin" ] || die "initdb finished but ${DATA_TOP}/pg_encryption/key.bin is missing. Empty ${DATA_TOP} and re-run."
if ! grep -q "^[[:space:]]*data_encryption_key_unwrap_command" "${DATA_TOP}/postgresql.conf"; then
    log_warn "initdb did not record the unwrap command; adding it to postgresql.conf."
    printf "data_encryption_key_unwrap_command = '%s'\n" "$THALES_UNWRAP_CMD" >> "${DATA_TOP}/postgresql.conf"
fi

# From here on a cluster exists: on failure it must be removed before a re-run (a re-run would see it as done)
UNVERIFIED="The cluster in ${DATA_TOP} is NOT verified. After fixing the cause, empty ${DATA_TOP} (it holds no data yet) and re-run."

# --- prove the server can unwrap the key: temporary start on PRIMARY_PORT, check, stop ---
log_info "Test start (pg_ctl, port ${PRIMARY_PORT})..."
sudo -u "$SYSTEM_USER" "${BIN}/pg_ctl" -D "$DATA_TOP" -o "-p ${PRIMARY_PORT}" -l "${DATA_TOP}/tde_first_start.log" -w -t 120 start \
    || die "Server did not start - see ${DATA_TOP}/tde_first_start.log (key unwrap through Thales?). ${UNVERIFIED}"
TDE_VER=$(sudo -u "$SYSTEM_USER" "${BIN}/psql" -X -p "$PRIMARY_PORT" -d postgres -Atc "SELECT data_encryption_version FROM pg_control_init()" 2>/dev/null || true)
sudo -u "$SYSTEM_USER" "${BIN}/pg_ctl" -D "$DATA_TOP" -m fast -w stop >/dev/null
[ "$TDE_VER" = "1" ] || die "TDE check returned '${TDE_VER}' (expected 1). ${UNVERIFIED}"

log_audit "TDE cluster created in ${DATA_TOP} with Thales KMIP key ${THALES_KEY_UUID} (data_encryption_version=1)"
log_info "Next: run 01-provision/epas-base-build.sh (it keeps this cluster and adds the systemd setup and conf.d), then start ${SERVICE_NAME}."
log_info "The server needs Thales reachable at every start: it unwraps the key through KMIP each time."
