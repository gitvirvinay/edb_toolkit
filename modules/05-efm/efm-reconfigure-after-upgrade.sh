#!/usr/bin/env bash
# efm-reconfigure-after-upgrade.sh — point an existing EFM agent at the upgraded EPAS cluster
# (db.bin, db.data.dir, db.port, db.service.name, and db.config.dir if it followed the data dir).
# Run on primary and standby after a major upgrade (04-upgrade); not needed on a dedicated witness
# unless db.port changed. Replaces efm-reconfigure-for-epas17.sh (hard-coded, non-existent paths).
#
# Runs as the DBA (SYSTEM_USER), never as root. The EFM properties file lives in /etc and belongs to
# the efm user, so this script does NOT edit it: it reads it, builds the corrected copy in the toolkit's
# own folder, shows the differences, and prints the one root command the sysadmin runs to put it in place.
# Running it again after that says "already up to date" - that is the check that the step was done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

PROPS=""
OUT=""
usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--properties FILE] [--out FILE]
Run as SYSTEM_USER (the DBA), not root. Reads the EFM properties file (default
/etc/edb/efm-EFM_VERSION/EFM_CLUSTER_NAME.properties) and builds a corrected copy with:
  db.bin=SRC_BINARY_DIR/bin  db.data.dir=DATA_TOP  db.port=PRIMARY_PORT  db.service.name=SERVICE_NAME (if used)
The copy goes to <log directory>/efm/<cluster>.properties.epas<version> (or --out FILE), mode 600 (it holds the
encrypted database password). The real file is NOT changed: the sysadmin installs the copy (command printed at the end).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --properties) [ -n "${2:-}" ] || die "--properties needs a file"; PROPS="$2"; shift 2 ;;
        --out)        [ -n "${2:-}" ] || die "--out needs a file"; OUT="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            die "Unknown argument: $1 (see --help)" ;;
    esac
done
load_env required
[ "$(id -u)" -ne 0 ] || die "Do not run as root. Run as '${SYSTEM_USER}': the sysadmin only installs the finished file (the command is printed at the end)."
require_vars EFM_VERSION SRC_BINARY_DIR DATA_TOP PRIMARY_PORT SERVICE_NAME

CLUSTER="${EFM_CLUSTER_NAME:-efm}"
PROPS="${PROPS:-/etc/edb/efm-${EFM_VERSION}/${CLUSTER}.properties}"
CLUSTER="$(basename "$PROPS" .properties)"           # EFM's cluster name is the file name
# unit naming as in efm-setup.sh: packaged unit for "efm", efm-<cluster> for any other cluster
if [ "$CLUSTER" = "efm" ]; then UNIT="${EFM_SERVICE:-edb-efm-${EFM_VERSION}}"; else UNIT="efm-${CLUSTER}"; fi
NEW_BIN="${SRC_BINARY_DIR}/bin"
[ -f "$PROPS" ] || die "EFM properties file not found: ${PROPS} (use --properties)"
[ -r "$PROPS" ] || die "${PROPS} is not readable by $(whoami). Ask the sysadmin to make it readable for the DBA group, or to run the printed edits by hand."
[ -x "${NEW_BIN}/pg_ctl" ] || die "New EPAS binaries not found: ${NEW_BIN}"
[ -f "${DATA_TOP}/PG_VERSION" ] || die "New data directory not initialised: ${DATA_TOP}"
[ "$(get_property is.witness "$PROPS")" != "true" ] || log_warn "${PROPS} is a witness: only db.port is relevant there."

if [ -z "$OUT" ]; then
    LOGD="$(log_dir)"
    [ -n "$LOGD" ] && [ -d "$LOGD" ] && [ -w "$LOGD" ] || die "No writable toolkit log directory for the new file (${LOGD:-none}). Use --out FILE."
    OUT="${LOGD}/efm/${CLUSTER}.properties.epas${EPAS_VERSION}"
fi
OLD_DATA=$(get_property db.data.dir "$PROPS")
OLD_CONF=$(get_property db.config.dir "$PROPS")
OLD_SVC=$(get_property db.service.name "$PROPS")
show_config CLUSTER UNIT PROPS OUT NEW_BIN DATA_TOP PRIMARY_PORT SERVICE_NAME

umask 077
mkdir -p "$(dirname "$OUT")"
cp "$PROPS" "$OUT"; chmod 600 "$OUT"
if [ "$(get_property is.witness "$OUT")" = "true" ]; then
    set_property db.port "$PRIMARY_PORT" "$OUT"
else
    set_property db.bin      "$NEW_BIN"      "$OUT"
    set_property db.data.dir "$DATA_TOP"     "$OUT"
    set_property db.port     "$PRIMARY_PORT" "$OUT"
    [ -z "$OLD_SVC" ] || set_property db.service.name "$SERVICE_NAME" "$OUT"
    if [ -n "$OLD_CONF" ]; then
        if [ "$OLD_CONF" = "$OLD_DATA" ]; then set_property db.config.dir "$DATA_TOP" "$OUT"
        else log_warn "db.config.dir=${OLD_CONF} is separate from the data dir - left unchanged; check it by hand."; fi
    fi
fi

if cmp -s "$PROPS" "$OUT"; then
    rm -f "$OUT"
    log_info "${PROPS} is already up to date for EPAS ${EPAS_VERSION} - nothing to do."
    log_audit "EFM ${CLUSTER} properties already point at EPAS ${EPAS_VERSION} (${DATA_TOP}, port ${PRIMARY_PORT}); checked by $(whoami)"
    exit 0
fi

log_info "Changes to make in ${PROPS}:"
diff "$PROPS" "$OUT" | grep '^[<>]' | sed 's/^/    /' || true
log_audit "EFM ${CLUSTER}: corrected properties for EPAS ${EPAS_VERSION} prepared in ${OUT} by $(whoami); waiting for the sysadmin to install them"

# Same owner, group and mode as the file being replaced.
OWNER_GROUP_MODE="$(stat -c '%U %G %a' "$PROPS" 2>/dev/null || echo 'efm efm 600')"
read -r F_OWNER F_GROUP F_MODE <<<"$OWNER_GROUP_MODE"
STAMP="$(date +%Y%m%d%H%M%S)"
cat <<NEXT

Next:
  1. SYSADMIN, as root on $(hostname -s) (two commands; the first keeps a backup):
       cp -a ${PROPS} ${PROPS}.bak.${STAMP}
       install -o ${F_OWNER} -g ${F_GROUP} -m ${F_MODE} ${OUT} ${PROPS}
  2. DBA: run this script again - it should say "already up to date". Then delete ${OUT}
     (it holds the encrypted database password).
  3. DBA: restart the agent:  sudo systemctl restart ${UNIT}
     (${UNIT} must be in conf/sudoers.d/epas-automation; only edb-efm-${EFM_VERSION} is by default)
  4. DBA: check:  sudo $(efm_bin) cluster-status ${CLUSTER}
Do the same on the other database node(s); on a witness only db.port matters.
NEXT
