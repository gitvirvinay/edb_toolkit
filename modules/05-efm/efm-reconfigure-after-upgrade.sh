#!/usr/bin/env bash
# efm-reconfigure-after-upgrade.sh — point an existing EFM agent at the upgraded EPAS cluster
# (db.bin, db.data.dir, db.port, db.service.name, and db.config.dir if it followed the data dir).
# Run on primary and standby after a major upgrade (04-upgrade); not needed on a dedicated witness
# unless db.port changed. Replaces efm-reconfigure-for-epas17.sh (hard-coded, non-existent paths).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

PROPS=""
usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--properties FILE] [--yes]
Sets in the EFM properties file (default /etc/edb/efm-EFM_VERSION/EFM_CLUSTER_NAME.properties):
  db.bin=SRC_BINARY_DIR/bin  db.data.dir=DATA_TOP  db.port=PRIMARY_PORT  db.service.name=SERVICE_NAME (if used)
The file is backed up first and the changes are shown. EFM must be restarted afterwards (shown at the end).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --properties) [ -n "${2:-}" ] || die "--properties needs a file"; PROPS="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            die "Unknown argument: $1 (see --help)" ;;
    esac
done
require_root
load_env required
require_vars EFM_VERSION SRC_BINARY_DIR DATA_TOP PRIMARY_PORT SERVICE_NAME

CLUSTER="${EFM_CLUSTER_NAME:-efm}"
PROPS="${PROPS:-/etc/edb/efm-${EFM_VERSION}/${CLUSTER}.properties}"
CLUSTER="$(basename "$PROPS" .properties)"           # EFM's cluster name is the file name
# unit naming as in efm-setup.sh: packaged unit for "efm", efm-<cluster> for any other cluster
if [ "$CLUSTER" = "efm" ]; then UNIT="${EFM_SERVICE:-edb-efm-${EFM_VERSION}}"; else UNIT="efm-${CLUSTER}"; fi
NEW_BIN="${SRC_BINARY_DIR}/bin"
[ -f "$PROPS" ] || die "EFM properties file not found: ${PROPS} (use --properties)"
[ "$(get_property is.witness "$PROPS")" != "true" ] || log_warn "${PROPS} is a witness: only db.port is relevant there."
[ -x "${NEW_BIN}/pg_ctl" ] || die "New EPAS binaries not found: ${NEW_BIN}"
[ -f "${DATA_TOP}/PG_VERSION" ] || die "New data directory not initialised: ${DATA_TOP}"

OLD_DATA=$(get_property db.data.dir "$PROPS")
OLD_CONF=$(get_property db.config.dir "$PROPS")
OLD_SVC=$(get_property db.service.name "$PROPS")
show_config CLUSTER UNIT PROPS NEW_BIN DATA_TOP PRIMARY_PORT SERVICE_NAME
confirm_or_exit "update ${PROPS} for EPAS ${EPAS_VERSION}"

BACKUP="${PROPS}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$PROPS" "$BACKUP"
if [ "$(get_property is.witness "$PROPS")" = "true" ]; then
    set_property db.port "$PRIMARY_PORT" "$PROPS"
else
    set_property db.bin      "$NEW_BIN"      "$PROPS"
    set_property db.data.dir "$DATA_TOP"     "$PROPS"
    set_property db.port     "$PRIMARY_PORT" "$PROPS"
    [ -z "$OLD_SVC" ] || set_property db.service.name "$SERVICE_NAME" "$PROPS"
    if [ -n "$OLD_CONF" ]; then
        if [ "$OLD_CONF" = "$OLD_DATA" ]; then set_property db.config.dir "$DATA_TOP" "$PROPS"
        else log_warn "db.config.dir=${OLD_CONF} is separate from the data dir - left unchanged; check it by hand."; fi
    fi
fi
log_info "Changes (backup: ${BACKUP}):"
diff "$BACKUP" "$PROPS" | grep '^[<>]' | sed 's/^/    /' || log_info "    (no changes - already up to date)"
log_audit "EFM ${CLUSTER} re-pointed at EPAS ${EPAS_VERSION} (${DATA_TOP}, port ${PRIMARY_PORT}) by $(whoami)"

cat <<NEXT

Next:
  1. Do the same on the other database node(s); on a witness only db.port matters.
  2. Restart the agent on each node:  systemctl restart ${UNIT}
  3. Check:  $(efm_bin) cluster-status ${CLUSTER}
NEXT
