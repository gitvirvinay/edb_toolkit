#!/usr/bin/env bash
# efm-setup.sh — prepare the configuration of one EDB Failover Manager agent (primary, standby or witness) for one cluster.
# Run on every node of the cluster. Several clusters per node are supported, using EDB's documented layout:
#   /etc/edb/efm-<ver>/<cluster>.properties + <cluster>.nodes, and for a cluster not named "efm" a copy of the
#   packaged unit file as /etc/systemd/system/efm-<cluster>.service with CLUSTER= and PIDFile= changed.
# Replaces efm-interactive-cluster-setup.sh and efm-multi-cluster-setup.sh (see REORGANIZE_LOG.md).
#
# Runs as the DBA (SYSTEM_USER), never as root, and installs nothing. The package (dnf) and the files in /etc
# belong to the sysadmin: this script builds every file in a staging folder, compares it with what is installed,
# and prints the exact root commands for the sysadmin. Run it again afterwards: "already installed" = step done.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

ROLE=""; CLUSTER_OPT=""; OUT_DIR=""

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--role primary|standby|witness] [--cluster NAME] [--out DIR] [--yes]
Run as SYSTEM_USER (the DBA), not root. Builds <cluster>.properties and <cluster>.nodes (and, for a cluster not
named "efm", the systemd unit) in a staging folder (default <log directory>/efm/<cluster>/, mode 700), encrypts the
EFM database password, shows what differs from the installed files and prints the commands the SYSADMIN runs as root.
Needs the EFM package already installed (the sysadmin runs dnf). Every value is asked with the config value as
default; with --yes (or without a terminal) the config values are used as they are and --role is required.
  --role      this node's role (asked if omitted)
  --cluster   EFM cluster name (default: EFM_CLUSTER_NAME, else "efm")
  --out DIR   staging folder (default <log directory>/efm/<cluster>)
Password: set EFMPASS in the environment, or you are asked (blank = keep the installed one, or skip).
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
        --out)        [ -n "${2:-}" ] || die "--out needs a folder"; OUT_DIR="$2"; shift 2 ;;
        --no-install) die "--no-install was removed: this script never installs. The sysadmin installs the EFM package (dnf)." ;;
        --start)      die "--start was removed: the DBA starts the agent with 'sudo systemctl enable <unit>' and 'sudo systemctl start <unit>' (printed at the end)." ;;
        -h|--help)    usage ;;
        *)            die "Unknown argument: $1 (see --help)" ;;
    esac
done

load_env required
[ "$(id -u)" -ne 0 ] || die "Do not run as root. Run as '${SYSTEM_USER}': the sysadmin only runs the commands printed at the end."

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
EFM_ROOT="${EFM_CONF_DIR:-/etc/edb/efm-${EFM_VERSION}}"
EFM_CMD="${EFM_BIN:-/usr/edb/efm-${EFM_VERSION}/bin/efm}"
PROPERTIES="${EFM_ROOT}/${CLUSTER}.properties"
NODES="${EFM_ROOT}/${CLUSTER}.nodes"
PKG_UNIT="${EFM_PKG_UNIT:-/usr/lib/systemd/system/edb-efm-${EFM_VERSION}.service}"
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

# --- STAGING FOLDER ---
if [ -z "$OUT_DIR" ]; then
    LOGD="$(log_dir)"
    { [ -n "$LOGD" ] && [ -d "$LOGD" ] && [ -w "$LOGD" ]; } || die "No writable toolkit log directory for the staging folder (${LOGD:-none}). Use --out DIR."
    OUT_DIR="${LOGD}/efm/${CLUSTER}"
fi

NODE_COUNT=2; [ -n "$W_HOST" ] && NODE_COUNT=3
show_config CLUSTER ROLE EFM_VERSION PROPERTIES NODES UNIT OUT_DIR BIND_HOST BIND_PORT ADMIN_PORT P_HOST S_HOST W_HOST \
            DB_PORT DB_USER DB_NAME DB_OWNER DB_SERVICE DB_BIN DB_DATA PING_IP VIP
[ "$NODE_COUNT" -ge 3 ] || log_warn "Only 2 nodes: EFM needs a third agent (witness or second standby) to fail over automatically."
confirm_or_exit "prepare the EFM ${EFM_VERSION} files for agent '${CLUSTER}' as ${ROLE} on this node (nothing is installed)"

# --- THE PACKAGE MUST BE THERE (the sysadmin installs it) ---
rpm -q "$EFM_PKG" >/dev/null 2>&1 \
    || die "${EFM_PKG} is not installed. Ask the sysadmin to run, as root:  dnf install -y ${EFM_PKG}   (needs the EDB repository). Then run this script again."
[ -x "$EFM_CMD" ] || die "efm not found at ${EFM_CMD} (is ${EFM_PKG} installed?)"
for f in "${EFM_ROOT}/efm.properties.in" "${EFM_ROOT}/efm.nodes.in"; do
    [ -r "$f" ] || die "Template ${f} is missing or not readable by $(whoami). Ask the sysadmin to make it readable for the DBA group."
done
[ "$IS_WITNESS" = true ] || [ -x "${DB_BIN}/pg_ctl" ] || log_warn "${DB_BIN}/pg_ctl not found - check the database bin directory."

# --- PORT CLASH WITH OTHER CLUSTERS ON THIS NODE ---
for other in "${EFM_ROOT}"/*.properties; do
    [ -f "$other" ] && [ "$other" != "$PROPERTIES" ] || continue
    [ -r "$other" ] || { log_warn "Cannot read ${other}: its ports were not compared with this cluster's."; continue; }
    o_admin=$(get_property admin.port "$other"); o_bind=$(get_property bind.address "$other")
    [ "$o_admin" != "$ADMIN_PORT" ] || die "admin.port ${ADMIN_PORT} is already used by $(basename "$other")."
    [ "${o_bind##*:}" != "$BIND_PORT" ] || die "Agent port ${BIND_PORT} is already used by $(basename "$other")."
done

# --- PASSWORD (encrypted with the cluster name; re-encrypt if the cluster is renamed) ---
OLD_PW=""; [ -r "$PROPERTIES" ] && OLD_PW=$(get_property db.password.encrypted "$PROPERTIES")
ENC_PW=""
if [ -z "${EFMPASS:-}" ] && [ "$INTERACTIVE" = true ]; then
    read -r -s -p "Password of database user '${DB_USER}' (blank = keep the installed one / skip): " EFMPASS; echo
fi
if [ -n "${EFMPASS:-}" ]; then
    if ENC_PW=$(EFMPASS="$EFMPASS" "$EFM_CMD" encrypt "$CLUSTER" --from-env 2>/dev/null | tail -n 1 | tr -d '[:space:]') \
       && [[ "$ENC_PW" =~ ^[0-9A-Fa-f]+$ ]]; then
        :
    else
        ENC_PW=""
        log_warn "'efm encrypt' did not work for $(whoami). Have the sysadmin (or the efm user) run it: EFMPASS=... ${EFM_CMD} encrypt ${CLUSTER} --from-env  and put the result in db.password.encrypted of ${PROPERTIES}."
    fi
fi

# --- BUILD THE FILES IN THE STAGING FOLDER ---
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
S_PROPS="${OUT_DIR}/${CLUSTER}.properties"; S_NODES="${OUT_DIR}/${CLUSTER}.nodes"
cp "${EFM_ROOT}/efm.properties.in" "$S_PROPS"
{ printf '%s:%s\n' "$P_HOST" "$BIND_PORT" "$S_HOST" "$BIND_PORT"; [ -z "$W_HOST" ] || printf '%s:%s\n' "$W_HOST" "$BIND_PORT"; } > "$S_NODES"

set_property bind.address      "${BIND_HOST}:${BIND_PORT}" "$S_PROPS"
set_property admin.port        "$ADMIN_PORT"  "$S_PROPS"
set_property is.witness        "$IS_WITNESS"  "$S_PROPS"
set_property db.port           "$DB_PORT"     "$S_PROPS"
set_property db.user           "$DB_USER"     "$S_PROPS"
set_property db.database       "$DB_NAME"     "$S_PROPS"
set_property auto.allow.hosts  false          "$S_PROPS"
set_property stable.nodes.file true           "$S_PROPS"
if [ "$IS_WITNESS" = false ]; then
    set_property db.service.owner "$DB_OWNER"   "$S_PROPS"
    set_property db.service.name  "$DB_SERVICE" "$S_PROPS"
    set_property db.bin           "$DB_BIN"     "$S_PROPS"
    set_property db.data.dir      "$DB_DATA"    "$S_PROPS"
fi
[ -z "$PING_IP" ] || set_property ping.server.ip "$PING_IP" "$S_PROPS"
[ -z "$EMAIL" ]   || set_property user.email     "$EMAIL"   "$S_PROPS"
if [ -n "$VIP" ]; then
    set_property virtual.ip           "$VIP"                    "$S_PROPS"
    set_property virtual.ip.interface "${VIP_INTERFACE:-eth0}"  "$S_PROPS"
    set_property virtual.ip.prefix    "${VIP_PREFIX:-24}"       "$S_PROPS"
fi
if [ -n "$ENC_PW" ]; then
    set_property db.password.encrypted "$ENC_PW" "$S_PROPS"
elif [ -n "$OLD_PW" ]; then
    set_property db.password.encrypted "$OLD_PW" "$S_PROPS"
    log_info "Kept db.password.encrypted from the installed ${CLUSTER}.properties."
fi
chmod 600 "$S_PROPS" "$S_NODES"
[ "$(get_property ping.server.ip "$S_PROPS")" != "8.8.8.8" ] \
    || log_warn "ping.server.ip is 8.8.8.8 (template default). If the nodes can't reach it, set EFM_PING_SERVER_IP (e.g. the gateway)."

S_UNIT=""; UNIT_FILE=""
if [ "$CLUSTER" != "efm" ]; then
    [ -r "$PKG_UNIT" ] || die "Packaged unit not found or not readable: ${PKG_UNIT}"
    grep -q '^Environment=CLUSTER=' "$PKG_UNIT" && grep -q '^PIDFile=' "$PKG_UNIT" \
        || die "${PKG_UNIT} has no Environment=CLUSTER= / PIDFile= line - copy and edit it by hand (EDB docs: running multiple agents)."
    UNIT_FILE="/etc/systemd/system/${UNIT}.service"; S_UNIT="${OUT_DIR}/${UNIT}.service"
    sed -e "s|^Environment=CLUSTER=.*|Environment=CLUSTER=${CLUSTER}|" \
        -e "s|^PIDFile=\(.*\)/[^/]*\.pid$|PIDFile=\1/${CLUSTER}.pid|" "$PKG_UNIT" > "$S_UNIT"
    chmod 644 "$S_UNIT"
    log_info "Unit ${S_UNIT}: $(grep -E '^(Environment=CLUSTER|PIDFile)=' "$S_UNIT" | tr '\n' ' ')"
fi

# --- WHAT THE SYSADMIN STILL HAS TO DO: compare each staged file with the installed one ---
STAMP=$(date +%Y%m%d%H%M%S)
PLAN=()
# plan_file STAGED INSTALLED OWNER GROUP MODE
plan_file() {
    if [ -e "$2" ] && [ ! -r "$2" ]; then
        PLAN+=("# ${2} exists but the DBA cannot read it: cannot compare" "cp -a ${2} ${2}.bak.${STAMP}" "install -o $3 -g $4 -m $5 $1 $2"); return
    fi
    if [ -f "$2" ] && cmp -s "$1" "$2"; then log_info "${2}: already installed (same as the staged file)."; return; fi
    if [ -f "$2" ]; then
        log_info "${2} differs from what this script built (installing it would replace these lines):"
        diff "$2" "$1" | grep '^[<>]' | grep -v 'db.password.encrypted' | sed 's/^/    /' || true
        PLAN+=("cp -a ${2} ${2}.bak.${STAMP}")
    fi
    PLAN+=("install -o $3 -g $4 -m $5 $1 $2")
}
plan_file "$S_PROPS" "$PROPERTIES" efm efm 600
plan_file "$S_NODES" "$NODES" efm efm 600
if [ -n "$S_UNIT" ]; then
    n=${#PLAN[@]}
    plan_file "$S_UNIT" "$UNIT_FILE" root root 644
    [ "${#PLAN[@]}" -eq "$n" ] || PLAN+=("systemctl daemon-reload")
fi

log_audit "EFM ${EFM_VERSION} agent '${CLUSTER}' (${ROLE}, ${BIND_HOST}:${BIND_PORT}, admin ${ADMIN_PORT}) prepared in ${OUT_DIR} by $(whoami); sysadmin steps pending: ${#PLAN[@]}"
[ -n "$ENC_PW$OLD_PW" ] || log_warn "db.password.encrypted is not set: run  EFMPASS=... ${EFM_CMD} encrypt ${CLUSTER} --from-env  and put the result in ${PROPERTIES}."
[ "$UNIT" = "${EFM_SERVICE:-}" ] || log_warn "conf: EFM_SERVICE=${EFM_SERVICE:-<unset>} but this agent's unit is ${UNIT} - set EFM_SERVICE=\"${UNIT}\" so 03-patching controls the right agent."

if [ "${#PLAN[@]}" -eq 0 ]; then
    echo
    echo "Everything is installed as prepared: no root step is needed for cluster '${CLUSTER}'. Go on with step 2 below."
else
    echo
    echo "Next steps for cluster '${CLUSTER}':"
    echo "  1. SYSADMIN, as root on $(hostname -s):"
    printf '       %s\n' "${PLAN[@]}"
    echo "     Then the DBA runs this script again: it should say 'already installed'. Delete ${OUT_DIR} afterwards (it holds the encrypted password)."
fi
cat <<NEXT
  2. Database: user '${DB_USER}' must exist with the password you encrypted, and pg_hba.conf on primary and
     standby must allow it from every node: ${P_HOST} ${S_HOST} ${W_HOST}
  3. SYSADMIN, firewall on every node:  firewall-cmd --permanent --add-port=${BIND_PORT}/tcp --add-port=${ADMIN_PORT}/tcp && firewall-cmd --reload
  4. DBA, start the primary's agent first:  sudo systemctl enable ${UNIT}  &&  sudo systemctl start ${UNIT}
     (${UNIT} must be in conf/sudoers.d/epas-automation; only edb-efm-${EFM_VERSION} is by default)
     auto.allow.hosts=false, so on that node the sysadmin (root or the efm user) allows the others before they start:
       ${EFM_CMD} allow-node ${CLUSTER} ${S_HOST}$([ -n "$W_HOST" ] && printf '\n       %s allow-node %s %s' "$EFM_CMD" "$CLUSTER" "$W_HOST")
  5. Then the DBA starts the others the same way and checks:  sudo ${EFM_CMD} cluster-status ${CLUSTER}
NEXT
