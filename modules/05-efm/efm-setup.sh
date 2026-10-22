#!/usr/bin/env bash
# efm-setup.sh — install and configure one EDB Failover Manager agent (primary, standby or witness) for one cluster.
# Run on every node of the cluster. Several clusters per node are supported, using EDB's documented layout:
#   /etc/edb/efm-<ver>/<cluster>.properties + <cluster>.nodes, and for a cluster not named "efm" a copy of the
#   packaged unit file as /etc/systemd/system/efm-<cluster>.service with CLUSTER= and PIDFile= changed.
# Replaces efm-interactive-cluster-setup.sh and efm-multi-cluster-setup.sh (see REORGANIZE_LOG.md).
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

ROLE=""; CLUSTER_OPT=""; DO_INSTALL=true; DO_START=false

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--role primary|standby|witness] [--cluster NAME] [--no-install] [--start] [--yes]
Installs the EFM package (dnf), writes <cluster>.properties and <cluster>.nodes, encrypts the EFM database
password, and sets up the systemd unit. Every value is asked with the config value as default;
with --yes (or without a terminal) the config values are used as they are and --role is required.
  --role      this node's role (asked if omitted)
  --cluster   EFM cluster name (default: EFM_CLUSTER_NAME, else "efm")
  --no-install  skip 'dnf install' (package already installed)
  --start     enable and start the agent at the end (start the primary's agent first, then the others)
Password: set EFMPASS in the environment, or you are asked (blank = skip and do it later with 'efm encrypt').
Config (default conf/site.env): EFM_VERSION, EFM_CLUSTER_NAME, PRIMARY_HOST, STANDBY_HOST, WITNESS_HOST, PRIMARY_PORT,
EFM_DB_USER, EFM_DB_NAME, EFM_BIND_PORT, EFM_ADMIN_PORT, EFM_PING_SERVER_IP, EFM_USER_EMAIL,
SYSTEM_USER, SERVICE_NAME, SRC_BINARY_DIR, DATA_TOP, VIP_ADDRESS, VIP_INTERFACE, VIP_PREFIX.
USAGE
    exit 0
}

parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)       [ -n "${2:-}" ] || die "--role needs primary|standby|witness"; ROLE="$2"; shift 2 ;;
        --cluster)    [ -n "${2:-}" ] || die "--cluster needs a name"; CLUSTER_OPT="$2"; shift 2 ;;
        --no-install) DO_INSTALL=false; shift ;;
        --start)      DO_START=true; shift ;;
        -h|--help)    usage ;;
        *)            die "Unknown argument: $1 (see --help)" ;;
    esac
done

require_root
load_env required

INTERACTIVE=true; { [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; } && INTERACTIVE=false
# ask VAR "question" DEFAULT [optional] — interactive: prompt with default; otherwise take the default
ask() {
    local __var="$1" q="$2" def="${3:-}" opt="${4:-}" a=""
    if [ "$INTERACTIVE" = true ]; then
        read -r -p "${q}${def:+ [${def}]}: " a
        a="${a:-$def}"
        while [ -z "$a" ] && [ -z "$opt" ]; do read -r -p "${q} (required): " a; done
    else
        a="$def"
        [ -n "$a" ] || [ -n "$opt" ] || die "No value for: ${q} - set it in ${ENV_SOURCE} or run interactively."
    fi
    printf -v "$__var" '%s' "$a"
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }

# --- CLUSTER / VERSION / PATHS ---
ask CLUSTER "EFM cluster name" "${CLUSTER_OPT:-${EFM_CLUSTER_NAME:-efm}}"
[[ "$CLUSTER" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid cluster name '${CLUSTER}': letters, digits, _ and - only."
[[ "$EFM_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "EFM_VERSION must look like 5.3 (got '${EFM_VERSION}')."
EFM_PKG="edb-efm${EFM_VERSION//./}"
EFM_ROOT="/etc/edb/efm-${EFM_VERSION}"
EFM_CMD="/usr/edb/efm-${EFM_VERSION}/bin/efm"
PROPERTIES="${EFM_ROOT}/${CLUSTER}.properties"
NODES="${EFM_ROOT}/${CLUSTER}.nodes"
PKG_UNIT="/usr/lib/systemd/system/edb-efm-${EFM_VERSION}.service"
if [ "$CLUSTER" = "efm" ]; then
    UNIT="edb-efm-${EFM_VERSION}"                       # the packaged unit, used as shipped
else
    UNIT="efm-${CLUSTER}"                               # EDB docs: one copied unit per extra cluster
fi

# --- ROLE ---
if [ -z "$ROLE" ]; then
    [ "$INTERACTIVE" = true ] || die "--role primary|standby|witness is required with --yes / without a terminal."
    ask ROLE "This node's role (primary/standby/witness)" ""
fi
case "$ROLE" in primary|standby) IS_WITNESS=false ;; witness) IS_WITNESS=true ;; *) die "Invalid role '${ROLE}'." ;; esac

# --- NODES / PORTS ---
ask P_HOST "Primary address" "${PRIMARY_HOST:-}"
ask S_HOST "Standby address" "${STANDBY_HOST:-}"
ask W_HOST "Witness address (blank = none)" "${WITNESS_HOST:-}" optional
case "$ROLE" in primary) BIND_HOST="$P_HOST" ;; standby) BIND_HOST="$S_HOST" ;; witness) BIND_HOST="$W_HOST" ;; esac
[ -n "$BIND_HOST" ] || die "This node is the witness but no witness address was given."
ask BIND_PORT  "EFM agent port (unique per cluster on this node)" "${EFM_BIND_PORT:-7800}"
ask ADMIN_PORT "EFM admin port (unique per cluster on this node)" "${EFM_ADMIN_PORT:-7809}"
valid_port "$BIND_PORT" && valid_port "$ADMIN_PORT" || die "Invalid port number."
[ "$BIND_PORT" != "$ADMIN_PORT" ] || die "Agent port and admin port must differ."

# --- DATABASE ---
ask DB_PORT "Database port" "${PRIMARY_PORT}"
ask DB_USER "Database user for EFM" "${EFM_DB_USER:-efm}"
ask DB_NAME "Database EFM connects to" "${EFM_DB_NAME:-edb}"
valid_port "$DB_PORT" || die "Invalid database port."
if [ "$IS_WITNESS" = false ]; then
    ask DB_OWNER   "OS owner of the database service" "${SYSTEM_USER}"
    ask DB_SERVICE "Database systemd service" "${SERVICE_NAME}"
    ask DB_BIN     "Database bin directory" "${SRC_BINARY_DIR:+${SRC_BINARY_DIR}/bin}"
    ask DB_DATA    "Database data directory" "${DATA_TOP:-}"
fi
ask PING_IP "Address every node can ping (blank = template default)" "${EFM_PING_SERVER_IP:-}" optional
ask EMAIL   "Notification e-mail (blank = none)" "${EFM_USER_EMAIL:-}" optional
VIP="${VIP_ADDRESS:-}"

NODE_COUNT=2; [ -n "$W_HOST" ] && NODE_COUNT=3
show_config CLUSTER ROLE EFM_VERSION PROPERTIES NODES UNIT BIND_HOST BIND_PORT ADMIN_PORT P_HOST S_HOST W_HOST \
            DB_PORT DB_USER DB_NAME DB_OWNER DB_SERVICE DB_BIN DB_DATA PING_IP VIP
[ "$NODE_COUNT" -ge 3 ] || log_warn "Only 2 nodes: EFM needs a third agent (witness or second standby) to fail over automatically."
confirm_or_exit "configure EFM ${EFM_VERSION} agent '${CLUSTER}' as ${ROLE} on this node"

# --- INSTALL ---
if [ "$DO_INSTALL" = true ]; then
    if rpm -q "$EFM_PKG" >/dev/null 2>&1; then log_info "${EFM_PKG} already installed."
    else log_info "Installing ${EFM_PKG}..."; dnf install -y "$EFM_PKG" || die "dnf install ${EFM_PKG} failed - check the EDB repository."; fi
fi
[ -x "$EFM_CMD" ] || die "efm not found at ${EFM_CMD} (is ${EFM_PKG} installed?)"
for f in "${EFM_ROOT}/efm.properties.in" "${EFM_ROOT}/efm.nodes.in"; do [ -f "$f" ] || die "Template missing: $f"; done
[ "$IS_WITNESS" = true ] || [ -x "${DB_BIN}/pg_ctl" ] || log_warn "${DB_BIN}/pg_ctl not found - check the database bin directory."

# --- PORT CLASH WITH OTHER CLUSTERS ON THIS NODE ---
for other in "${EFM_ROOT}"/*.properties; do
    [ -f "$other" ] && [ "$other" != "$PROPERTIES" ] || continue
    o_admin=$(get_property admin.port "$other"); o_bind=$(get_property bind.address "$other")
    [ "$o_admin" != "$ADMIN_PORT" ] || die "admin.port ${ADMIN_PORT} is already used by $(basename "$other")."
    [ "${o_bind##*:}" != "$BIND_PORT" ] || die "Agent port ${BIND_PORT} is already used by $(basename "$other")."
done

# --- PASSWORD (encrypted with the cluster name; re-encrypt if the cluster is renamed) ---
ENC_PW=""
if [ -z "${EFMPASS:-}" ] && [ "$INTERACTIVE" = true ]; then
    read -r -s -p "Password of database user '${DB_USER}' (blank = skip): " EFMPASS; echo
fi
if [ -n "${EFMPASS:-}" ]; then
    ENC_PW=$(EFMPASS="$EFMPASS" "$EFM_CMD" encrypt "$CLUSTER" --from-env | tail -n 1 | tr -d '[:space:]')
    [[ "$ENC_PW" =~ ^[0-9A-Fa-f]+$ ]] || die "efm encrypt did not return an encrypted password."
fi

# --- PROPERTIES + NODES (from the package templates; existing files backed up) ---
STAMP=$(date +%Y%m%d%H%M%S)
for f in "$PROPERTIES" "$NODES"; do
    [ -e "$f" ] && { cp -a "$f" "${f}.bak.${STAMP}"; log_info "Backed up ${f} -> ${f}.bak.${STAMP}"; }
done
OLD_PW=""; [ -f "${PROPERTIES}.bak.${STAMP}" ] && OLD_PW=$(get_property db.password.encrypted "${PROPERTIES}.bak.${STAMP}")
cp "${EFM_ROOT}/efm.properties.in" "$PROPERTIES"
{ printf '%s:%s\n' "$P_HOST" "$BIND_PORT" "$S_HOST" "$BIND_PORT"; [ -z "$W_HOST" ] || printf '%s:%s\n' "$W_HOST" "$BIND_PORT"; } > "$NODES"

set_property bind.address      "${BIND_HOST}:${BIND_PORT}" "$PROPERTIES"
set_property admin.port        "$ADMIN_PORT"  "$PROPERTIES"
set_property is.witness        "$IS_WITNESS"  "$PROPERTIES"
set_property db.port           "$DB_PORT"     "$PROPERTIES"
set_property db.user           "$DB_USER"     "$PROPERTIES"
set_property db.database       "$DB_NAME"     "$PROPERTIES"
set_property auto.allow.hosts  false          "$PROPERTIES"
set_property stable.nodes.file true           "$PROPERTIES"
if [ "$IS_WITNESS" = false ]; then
    set_property db.service.owner "$DB_OWNER"   "$PROPERTIES"
    set_property db.service.name  "$DB_SERVICE" "$PROPERTIES"
    set_property db.bin           "$DB_BIN"     "$PROPERTIES"
    set_property db.data.dir      "$DB_DATA"    "$PROPERTIES"
fi
[ -z "$PING_IP" ] || set_property ping.server.ip "$PING_IP" "$PROPERTIES"
[ -z "$EMAIL" ]   || set_property user.email     "$EMAIL"   "$PROPERTIES"
if [ -n "$VIP" ]; then
    set_property virtual.ip           "$VIP"                    "$PROPERTIES"
    set_property virtual.ip.interface "${VIP_INTERFACE:-eth0}"  "$PROPERTIES"
    set_property virtual.ip.prefix    "${VIP_PREFIX:-24}"       "$PROPERTIES"
fi
if [ -n "$ENC_PW" ]; then
    set_property db.password.encrypted "$ENC_PW" "$PROPERTIES"
elif [ -n "$OLD_PW" ]; then
    set_property db.password.encrypted "$OLD_PW" "$PROPERTIES"
    log_info "Kept db.password.encrypted from the previous ${CLUSTER}.properties."
fi
chown efm:efm "$PROPERTIES" "$NODES"
chmod 600 "$PROPERTIES" "$NODES"
[ "$(get_property ping.server.ip "$PROPERTIES")" != "8.8.8.8" ] \
    || log_warn "ping.server.ip is 8.8.8.8 (template default). If the nodes can't reach it, set EFM_PING_SERVER_IP (e.g. the gateway)."

# --- SYSTEMD UNIT ---
if [ "$CLUSTER" != "efm" ]; then
    [ -f "$PKG_UNIT" ] || die "Packaged unit not found: ${PKG_UNIT}"
    grep -q '^Environment=CLUSTER=' "$PKG_UNIT" && grep -q '^PIDFile=' "$PKG_UNIT" \
        || die "${PKG_UNIT} has no Environment=CLUSTER= / PIDFile= line - copy and edit it by hand (EDB docs: running multiple agents)."
    UNIT_FILE="/etc/systemd/system/${UNIT}.service"
    [ -e "$UNIT_FILE" ] && cp -a "$UNIT_FILE" "${UNIT_FILE}.bak.${STAMP}"
    sed -e "s|^Environment=CLUSTER=.*|Environment=CLUSTER=${CLUSTER}|" \
        -e "s|^PIDFile=\(.*\)/[^/]*\.pid$|PIDFile=\1/${CLUSTER}.pid|" "$PKG_UNIT" > "$UNIT_FILE"
    chmod 644 "$UNIT_FILE"
    systemctl daemon-reload
    log_info "Unit ${UNIT_FILE}: $(grep -E '^(Environment=CLUSTER|PIDFile)=' "$UNIT_FILE" | tr '\n' ' ')"
fi

log_audit "EFM ${EFM_VERSION} agent '${CLUSTER}' configured as ${ROLE} (${BIND_HOST}:${BIND_PORT}, admin ${ADMIN_PORT}) by $(whoami)"
[ -n "$ENC_PW$OLD_PW" ] || log_warn "db.password.encrypted is not set: run  EFMPASS=... ${EFM_CMD} encrypt ${CLUSTER} --from-env  and put the result in ${PROPERTIES}."
[ "$UNIT" = "${EFM_SERVICE:-}" ] || log_warn "conf: EFM_SERVICE=${EFM_SERVICE:-<unset>} but this agent's unit is ${UNIT} - set EFM_SERVICE=\"${UNIT}\" so 03-patching controls the right agent."

cat <<NEXT

Next steps for cluster '${CLUSTER}':
  1. Run this script on every node (primary, standby$([ -n "$W_HOST" ] && echo ", witness")).
  2. Database: user '${DB_USER}' must exist with the password you encrypted, and pg_hba.conf on primary and
     standby must allow it from every node: ${P_HOST} ${S_HOST} ${W_HOST}
  3. Firewall on every node:  firewall-cmd --permanent --add-port=${BIND_PORT}/tcp --add-port=${ADMIN_PORT}/tcp && firewall-cmd --reload
  4. Start the primary's agent first:  systemctl enable --now ${UNIT}
     auto.allow.hosts=false, so on that node allow the others before starting them:
       ${EFM_CMD} allow-node ${CLUSTER} ${S_HOST}$([ -n "$W_HOST" ] && printf '\n       %s allow-node %s %s' "$EFM_CMD" "$CLUSTER" "$W_HOST")
  5. Then start the others and check:  ${EFM_CMD} cluster-status ${CLUSTER}
NEXT

if [ "$DO_START" = true ]; then
    systemctl enable --now "$UNIT"
    sleep 3
    "$EFM_CMD" cluster-status "$CLUSTER" || log_warn "cluster-status failed - see journalctl -u ${UNIT}"
fi
