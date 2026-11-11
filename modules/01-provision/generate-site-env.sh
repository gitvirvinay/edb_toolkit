#!/usr/bin/env bash
# ==============================================================================
# generate-site-env.sh  
#
# Detects the EPAS instance on this host (version, data directory, port, OS user,
# binaries, network), asks you to confirm each value, and writes conf/site.env
# built from conf/site.env.example.
#
# Usage: generate-site-env.sh [--instance <version|data dir>] [--force] [output_file]
#   --instance  choose the cluster when several are running (required when non-interactive)
#   --force     overwrite an existing output file without asking (old copy kept as .bak_<ts>)
#
# Needs: lib/common.sh (sets TOOLKIT_ROOT; may provide log/warn/die/log_audit) and
#        lib/epas-detect.sh (the toolkit's shared, read-only cluster detection).
#
# ------------------------------------------------------------------------------

# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/common.sh"
: "${TOOLKIT_ROOT:?lib/common.sh did not set TOOLKIT_ROOT}"

# Use common.sh's helpers when it has them (change 17)
# shellcheck source=../../lib/epas-detect.sh
source "${SCRIPT_DIR}/../../lib/epas-detect.sh"

declare -F log       >/dev/null || log()       { echo -e "\e[32m[INFO]\e[0m $*"; }
declare -F warn      >/dev/null || warn()      { echo -e "\e[33m[WARN]\e[0m $*" >&2; }
declare -F die       >/dev/null || die()       { echo -e "\e[31m[FATAL]\e[0m $*" >&2; exit 1; }
declare -F log_audit >/dev/null || log_audit() { :; }

TEMPLATE="${TOOLKIT_ROOT}/conf/site.env.example"
ENV_FILE="${TOOLKIT_ROOT}/conf/site.env"
FORCE=0
INSTANCE_ARG=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--instance <version|data dir>] [--force] [output_file]

Detects the EPAS version, data directory, port, OS user, binaries and network on this
host, asks you to confirm each value, and writes a config built from conf/site.env.example.

  --instance  pick the cluster when several are running (required when non-interactive),
              e.g. --instance 17  or  --instance /u001/data/as17
  --force     overwrite an existing output file without asking
              (the old file is kept as <file>.bak_<timestamp>)

Default output: conf/site.env in the toolkit. Run as root or the DB owner for full detection.
USAGE
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)    usage ;;
        --force)      FORCE=1; shift ;;
        --instance)   [ $# -ge 2 ] || die "--instance needs a version or a data directory"
                      INSTANCE_ARG="$2"; shift 2 ;;
        --instance=*) INSTANCE_ARG="${1#*=}"; shift ;;
        -*)           die "Unknown option: $1 (see --help)" ;;
        *)            ENV_FILE="$1"; shift ;;
    esac
done
[ -f "$TEMPLATE" ] || die "Template not found: $TEMPLATE"

INTERACTIVE=0; [ -t 0 ] && INTERACTIVE=1
RUN_AS="$(id -un)"
UNCONFIRMED=()

# =============================================================================
# HELPERS
# =============================================================================

# Running EPAS clusters, one line each: VERSION|PGDATA|PORT|PID|OWNER|MANAGED_BY|BINDIR
# From lib/epas-detect.sh; unknown values shown as '?', pg_ctl-started as manual/pg_ctl.
_detect_epas_instances() {
    local ver data port pid owner mgr bin _rest
    while IFS='|' read -r ver data port pid owner mgr bin _rest; do
        [[ -n $data ]] || continue
        [[ $mgr == pg_ctl ]] && mgr="manual/pg_ctl"
        echo "${ver:-?}|$data|${port:-?}|${pid:-?}|${owner:-?}|$mgr|$bin"
    done < <(epas_instances)
    return 0
}

# Any version-ish string -> bare number; argument or stdin; '' if none (changes 1, 2)
# Handles: 15 | as15 | edb-as15 | edb-as-15 | edb-as15-server | edb-as-15.service | /usr/edb/as15
normalize_epas_version() {
    local s
    if [[ $# -gt 0 ]]; then s=$1; else s=$(cat); fi
    grep -oE '[0-9]+' <<< "$s" | head -n1 || true
}

# Validators (change 13) - only characters that are safe in a sourced shell file
is_version()       { [[ $1 =~ ^[0-9]{1,3}$ ]]; }
is_version_like()  { [[ -n $(normalize_epas_version "$1") ]]; }
is_port()          { epas_is_valid_port "$1"; }
is_abs_path()      { [[ $1 == /* && $1 =~ ^[A-Za-z0-9._/+-]+$ && $1 != *..* ]]; }
is_abs_path_or_empty() { [[ -z $1 ]] || is_abs_path "$1"; }
is_account()       { [[ $1 =~ ^[A-Za-z_][A-Za-z0-9._-]{0,31}$ ]]; }
is_ipv4() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local i
    for i in 1 2 3 4; do (( 10#${BASH_REMATCH[i]} <= 255 )) || return 1; done
}
is_host()          { is_ipv4 "$1" || [[ ! $1 =~ ^[0-9.]+$ && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }
is_host_or_empty() { [[ -z $1 ]] || is_host "$1"; }
is_cidr() {
    [[ $1 == */* ]] || return 1
    local addr=${1%/*} len=${1#*/}
    is_ipv4 "$addr" && [[ $len =~ ^[0-9]{1,2}$ ]] && (( 10#$len <= 32 ))
}

# prompt_var TEXT DEFAULT VAR VALIDATOR [HINT]
# Interactive: re-asks until valid. Non-interactive: uses the default, dies if invalid,
# and records it as unconfirmed (change 16).
prompt_var() {
    local text=$1 def=$2 var=$3 check=$4 hint=${5:-} input
    while :; do
        input=""
        if (( INTERACTIVE )); then
            read -rp "${text} [default: ${def:-<empty>}]: " input || die "Input aborted"
        fi
        input=${input:-$def}
        if "$check" "$input"; then break; fi
        if (( ! INTERACTIVE )); then
            die "${text}: '${input}' is not valid${hint:+ ($hint)} and there is no terminal to ask - run interactively"
        fi
        warn "'${input}' is not valid${hint:+: $hint}"
    done
    if (( ! INTERACTIVE )); then UNCONFIRMED+=("${var}=${input:-<empty>}"); fi
    printf -v "$var" '%s' "$input"
}

# Installed versions, ascending (change 12)
installed_versions() {
    {
        epas_installed_versions /usr/edb
        if command -v rpm &>/dev/null; then
            rpm -qa --qf '%{NAME}\n' 'edb-as*-server' 2>/dev/null | sed -nE 's/^edb-as-?([0-9]+)-server$/\1/p'
        fi
    } | grep -E '^[0-9]+$' | sort -un || true
}

# Ports that have a live server socket in /tmp (readable by any user)
socket_ports() {
    local s
    for s in /tmp/.s.PGSQL.*; do
        if [[ -S $s ]]; then echo "${s##*.}"; fi
    done
    return 0
}

port_in_use() {
    command -v ss &>/dev/null || return 1
    ss -ltn "sport = :$1" 2>/dev/null | tail -n +2 | grep -q .
}

default_user() {
    local u
    for u in enterprisedb postgres; do
        if id "$u" &>/dev/null; then echo "$u"; return 0; fi
    done
    echo enterprisedb
}

# set_key FILE KEY VALUE: replace the first 'KEY=' / 'export KEY=' line, or append one.
# The value is shell-quoted with %q, so it can never execute when sourced (change 13).
set_key() {
    local f=$1 k=$2 v=$3 line tmp
    printf -v line '%s=%q' "$k" "$v"
    tmp=$(mktemp "${f}.XXXXXX")
    LINE="$line" awk -v k="$k" '
        BEGIN { done = 0 }
        !done && match($0, "^(export[ \t]+)?" k "=") {
            print substr($0, 1, RLENGTH - length(k) - 1) ENVIRON["LINE"]; done = 1; next
        }
        { print }
        END { if (!done) print ENVIRON["LINE"] }' "$f" > "$tmp"
    mv -f "$tmp" "$f"
}

# =============================================================================
# 1. RUNNING INSTANCE DETECTION (changes 3, 6, 9, 11)
# =============================================================================
log "Running as: ${RUN_AS}"
(( INTERACTIVE )) || warn "Non-interactive run: detected defaults are used without asking"

mapfile -t INSTANCES < <(_detect_epas_instances)

SEL=""
pick_instance() {
    local i n v d p pid o m
    local -a hits=()
    if [[ -n $INSTANCE_ARG ]]; then
        for i in "${!INSTANCES[@]}"; do
            IFS='|' read -r v d _ <<< "${INSTANCES[$i]}"
            if [[ $INSTANCE_ARG == "$v" || $INSTANCE_ARG == "$d" ]]; then hits+=("${INSTANCES[$i]}"); fi
        done
        case ${#hits[@]} in
            0) die "--instance '$INSTANCE_ARG' matches no running cluster" ;;
            1) SEL=${hits[0]}; return 0 ;;
            *) die "--instance '$INSTANCE_ARG' matches several clusters - give the data directory instead" ;;
        esac
    fi
    case ${#INSTANCES[@]} in
        0) return 0 ;;
        1) SEL=${INSTANCES[0]}; return 0 ;;
    esac
    log "Several EPAS instances are running:"
    for i in "${!INSTANCES[@]}"; do
        IFS='|' read -r v d p pid o m _ <<< "${INSTANCES[$i]}"
        printf '  %d) EPAS %-3s %-32s port %-5s owner %-12s %s\n' $((i + 1)) "$v" "$d" "$p" "$o" "$m"
    done
    (( INTERACTIVE )) || die "Several instances running: choose one with --instance <version|data dir>"
    while :; do
        read -rp "Which instance to configure? [1-${#INSTANCES[@]}]: " n || die "Input aborted"
        if [[ $n =~ ^[0-9]+$ ]] && (( 10#$n >= 1 && 10#$n <= ${#INSTANCES[@]} )); then
            SEL=${INSTANCES[10#$n - 1]}; return 0
        fi
        warn "Enter a number between 1 and ${#INSTANCES[@]}"
    done
}
pick_instance

DETECTED_VER="" DETECTED_DATA="" DETECTED_PORT="" DETECTED_PID="" DETECTED_OWNER="" DETECTED_MGR="" DETECTED_BIN=""
RUNNING=false
RUN_BIN_HOME=""
if [[ -n $SEL ]]; then
    IFS='|' read -r DETECTED_VER DETECTED_DATA DETECTED_PORT DETECTED_PID DETECTED_OWNER DETECTED_MGR DETECTED_BIN <<< "$SEL"
    # '?' means "could not be read" -> treat as unknown
    DETECTED_VER=${DETECTED_VER#\?}; DETECTED_PORT=${DETECTED_PORT#\?}
    DETECTED_PID=${DETECTED_PID#\?}; DETECTED_OWNER=${DETECTED_OWNER#\?}
    RUNNING=true
    log "Using running instance: EPAS ${DETECTED_VER:-?} at ${DETECTED_DATA} (${DETECTED_MGR})"
    # Binary tree the instance actually runs from (library: /proc/<pid>/exe, else the command line)
    if [[ $DETECTED_BIN == /*/bin ]]; then RUN_BIN_HOME=$(dirname "$DETECTED_BIN"); fi
else
    log "No running EPAS instance found - defaults come from installed packages and standard paths"
fi

# =============================================================================
# 2. EPAS VERSION (changes 1, 2, 12)
# =============================================================================
INSTALLED=$(installed_versions)
if [[ -z $DETECTED_VER && -n $INSTALLED ]]; then
    DETECTED_VER=$(tail -n1 <<< "$INSTALLED")
    log "Highest installed EPAS version: $DETECTED_VER"
fi

prompt_var "Enter EPAS Version" "${DETECTED_VER:-17}" EPAS_VERSION is_version_like "a number such as 17"
EPAS_VERSION=$(normalize_epas_version "$EPAS_VERSION")
is_version "$EPAS_VERSION" || die "Could not derive a numeric EPAS version from '${EPAS_VERSION}'"
log "Using EPAS version: ${EPAS_VERSION}"
if ! grep -qx "$EPAS_VERSION" <<< "$INSTALLED"; then
    warn "EPAS ${EPAS_VERSION} is not installed under /usr/edb (SRC_BINARY_DIR does not exist yet)"
fi
SRC_BINARY_DIR="/usr/edb/as${EPAS_VERSION}"

# Chose a different version than the running one? Its live values no longer apply.
if [[ $RUNNING == true && -n $DETECTED_VER && $EPAS_VERSION != "$DETECTED_VER" ]]; then
    warn "EPAS ${EPAS_VERSION} differs from the running instance (${DETECTED_VER}); not using its data dir, port or user as defaults"
    RUNNING=false
    DETECTED_DATA="" DETECTED_PORT="" DETECTED_OWNER="" RUN_BIN_HOME=""
fi
[[ $RUNNING == true ]] && warn "Values below default to the LIVE configuration of the running instance"

# =============================================================================
# 3. DATA_TOP & BINARY_TOP (changes 7, 19)
# =============================================================================
CLUSTER_DEFAULT="as${EPAS_VERSION}"
if [[ -z $DETECTED_DATA ]]; then
    if [[ -d /pgdata ]]; then
        DETECTED_DATA="/pgdata/${CLUSTER_DEFAULT}"
    elif [[ -d /u001 ]]; then
        DETECTED_DATA="/u001/data/as${EPAS_VERSION}"
    elif [[ -d /var/lib/edb ]]; then
        DETECTED_DATA="/var/lib/edb/as${EPAS_VERSION}/data"
    else
        DETECTED_DATA="/pgdata/${CLUSTER_DEFAULT}"
    fi
fi
prompt_var "Enter DATA_TOP directory" "$DETECTED_DATA" DATA_TOP is_abs_path \
           "absolute path using only letters, digits and . _ - + /"

if [[ -n $RUN_BIN_HOME && $RUN_BIN_HOME != "$SRC_BINARY_DIR" ]]; then
    DEFAULT_BIN_TOP=$RUN_BIN_HOME
elif [[ $DATA_TOP =~ ^(/[^/]+)/data/as[0-9]+(/data)?$ ]]; then
    DEFAULT_BIN_TOP="${BASH_REMATCH[1]}/binary/as${EPAS_VERSION}"
elif [[ $RUNNING == true || -f ${DATA_TOP}/PG_VERSION ]]; then
    DEFAULT_BIN_TOP=$SRC_BINARY_DIR          # existing install: where the binaries really are
else
    # New build: the binaries are moved out of /usr/edb (epas-base-build-root.sh refuses BINARY_TOP = SRC_BINARY_DIR)
    DEFAULT_BIN_TOP="/u001/binary/as${EPAS_VERSION}"
fi
prompt_var "Enter BINARY_TOP directory" "$DEFAULT_BIN_TOP" BINARY_TOP is_abs_path \
           "absolute path using only letters, digits and . _ - + /"

# =============================================================================
# 3b. STORAGE LAYOUT: WAL_TOP, ARCHIVE_TOP, BACKUP_TOP, LOG_TOP (empty = not used)
# =============================================================================
# Existing cluster: what it really uses (pg_wal symlink, absolute log_directory). New cluster:
# <mount>/<cluster> when the standard mount exists on this host, else empty (old layout).
mount_default() { if [[ -d $1 ]]; then echo "$1/${CLUSTER_DEFAULT}"; fi; }
DEF_WAL="" DEF_LOG=""
if [[ -f ${DATA_TOP}/PG_VERSION ]]; then
    if [[ -L ${DATA_TOP}/pg_wal ]]; then DEF_WAL=$(readlink -f "${DATA_TOP}/pg_wal"); fi
    LOGDIR=$(epas_conf_get "$DATA_TOP" log_directory 2>/dev/null || true)
    if [[ $LOGDIR == /* ]]; then DEF_LOG=$LOGDIR; fi
    log "Existing cluster in ${DATA_TOP}: pg_wal ${DEF_WAL:-inside PGDATA}, logs ${DEF_LOG:-inside PGDATA}"
else
    DEF_WAL=$(mount_default /pgwal)
    DEF_LOG=$(mount_default /pglog)
fi
DEF_ARCHIVE=$(mount_default /pgarchive)
DEF_BACKUP=$(mount_default /pgbackup)
LAYOUT_HINT="absolute path, or empty = not used"
prompt_var "Enter WAL_TOP (pg_wal on its own mount; empty = inside PGDATA)" "$DEF_WAL" WAL_TOP is_abs_path_or_empty "$LAYOUT_HINT"
prompt_var "Enter ARCHIVE_TOP (archived WAL / pgBackRest spool; empty = not used)" "$DEF_ARCHIVE" ARCHIVE_TOP is_abs_path_or_empty "$LAYOUT_HINT"
prompt_var "Enter BACKUP_TOP (local base backups; empty = not used)" "$DEF_BACKUP" BACKUP_TOP is_abs_path_or_empty "$LAYOUT_HINT"
prompt_var "Enter LOG_TOP (server logs; empty = 'log' inside PGDATA)" "$DEF_LOG" LOG_TOP is_abs_path_or_empty "$LAYOUT_HINT"
if [[ -z $WAL_TOP ]]; then warn "WAL_TOP is empty: pg_wal stays inside PGDATA (on the data disk)"; fi

# =============================================================================
# 4. SYSTEM_USER & SYSTEM_GROUP
# =============================================================================
prompt_var "Enter System User" "${DETECTED_OWNER:-$(default_user)}" SYSTEM_USER is_account "a valid OS user name"
if ! id "$SYSTEM_USER" &>/dev/null; then warn "OS user '$SYSTEM_USER' does not exist on this host yet"; fi

DETECTED_GROUP=$(id -gn "$SYSTEM_USER" 2>/dev/null || echo "$SYSTEM_USER")
prompt_var "Enter System Group" "$DETECTED_GROUP" SYSTEM_GROUP is_account "a valid OS group name"

# Change 11: PGDATA is mode 0700 - only root and the owner can read the port from it
if [[ $EUID -ne 0 && $RUN_AS != "$SYSTEM_USER" ]]; then
    warn "Running as '${RUN_AS}' (not root or ${SYSTEM_USER}): files inside DATA_TOP are not readable, so the port may fall back to a default"
fi

# =============================================================================
# 5. PRIMARY_PORT (changes 4, 5, 10)
# =============================================================================
PORT_SRC=""
if [[ -n $DETECTED_PORT ]]; then
    PORT_SRC="the running instance"
else
    DETECTED_PORT=$(epas_conf_get "$DATA_TOP" port)
    [[ $DETECTED_PORT =~ ^[0-9]+$ ]] || DETECTED_PORT=""
    if [[ -n $DETECTED_PORT ]]; then PORT_SRC="the config files in ${DATA_TOP}"; fi
fi
if [[ -z $DETECTED_PORT ]]; then
    mapfile -t SOCKS < <(socket_ports)
    if [[ $RUNNING == true && ${#INSTANCES[@]} -eq 1 && ${#SOCKS[@]} -eq 1 ]]; then
        DETECTED_PORT=${SOCKS[0]}; PORT_SRC="socket /tmp/.s.PGSQL.${SOCKS[0]}"
    elif (( ${#SOCKS[@]} > 0 )); then
        warn "Server sockets exist for port(s) ${SOCKS[*]}, but it is not clear which belongs to this instance"
    fi
fi
if [[ -n $PORT_SRC ]]; then log "Detected port ${DETECTED_PORT} from ${PORT_SRC}"; fi

prompt_var "Enter Primary Database Port" "${DETECTED_PORT:-5444}" PRIMARY_PORT is_port "1-65535"
if [[ $RUNNING != true || $PRIMARY_PORT != "$DETECTED_PORT" ]] && port_in_use "$PRIMARY_PORT"; then
    warn "Port ${PRIMARY_PORT} is already in use by another process on this host"
fi

# =============================================================================
# 6. NETWORK (changes 8, 14)
# =============================================================================
DEFAULT_IP=$(epas_primary_ip)
DEFAULT_CIDR=$(epas_subnet "$DEFAULT_IP")

prompt_var "Enter Primary Host IP" "$DEFAULT_IP" PRIMARY_HOST is_host "IPv4 address or host name"
prompt_var "Enter Subnet CIDR" "$DEFAULT_CIDR" SUBNET_CIDR is_cidr "e.g. 10.0.1.0/24"
prompt_var "Enter Standby Host IP (leave empty if not known yet)" "" STANDBY_HOST is_host_or_empty \
           "IPv4 address, host name, or empty"

# =============================================================================
# 7. SUMMARY & CONFIRMATION (change 20)
# =============================================================================
echo
log "Configuration for ${ENV_FILE}:"
printf '  %-15s %s\n' \
    EPAS_VERSION   "$EPAS_VERSION" \
    SYSTEM_USER    "$SYSTEM_USER" \
    SYSTEM_GROUP   "$SYSTEM_GROUP" \
    SRC_BINARY_DIR "$SRC_BINARY_DIR" \
    BINARY_TOP     "$BINARY_TOP" \
    DATA_TOP       "$DATA_TOP" \
    WAL_TOP        "${WAL_TOP:-<empty - inside PGDATA>}" \
    ARCHIVE_TOP    "${ARCHIVE_TOP:-<empty - not used>}" \
    BACKUP_TOP     "${BACKUP_TOP:-<empty - not used>}" \
    LOG_TOP        "${LOG_TOP:-<empty - inside PGDATA>}" \
    PRIMARY_PORT   "$PRIMARY_PORT" \
    PRIMARY_HOST   "$PRIMARY_HOST" \
    SUBNET_CIDR    "$SUBNET_CIDR" \
    STANDBY_HOST   "${STANDBY_HOST:-<empty - set before configuring replication>}"
echo "  Other settings (EFM, STANZA, VIP, TDE) keep the template defaults - review them in the file."
if (( INTERACTIVE )); then
    read -rp "Write this configuration? (Y/n): " ok || die "Input aborted"
    [[ -z $ok || $ok =~ ^[Yy] ]] || die "Aborted - nothing written"
fi

# =============================================================================
# 8. WRITE (changes 13, 15)
# =============================================================================
if [ -e "$ENV_FILE" ] && [ "$FORCE" -ne 1 ]; then
    if (( INTERACTIVE )); then
        read -rp "$ENV_FILE already exists. Overwrite it (old copy kept as .bak)? (y/N): " ow || die "Input aborted"
        [[ $ow =~ ^[Yy]$ ]] || die "Not overwritten. Use another output file or --force."
    else
        die "$ENV_FILE already exists. Not overwriting (use --force)."
    fi
fi

OUT_DIR=$(dirname "$ENV_FILE")
mkdir -p "$OUT_DIR"
TMP_OUT=$(mktemp "${OUT_DIR}/.site.env.XXXXXX")
trap 'rm -f "$TMP_OUT" "$TMP_OUT".*' EXIT

{
    echo "# Generated by $(basename "$0") on $(date -u '+%F %T') UTC on host $(hostname -s 2>/dev/null || hostname)"
    echo "# Run as ${RUN_AS}, from conf/site.env.example with detected/confirmed values. Review before use."
    cat "$TEMPLATE"
} > "$TMP_OUT"

for kv in "EPAS_VERSION=$EPAS_VERSION" "SYSTEM_USER=$SYSTEM_USER" "SYSTEM_GROUP=$SYSTEM_GROUP" \
          "SRC_BINARY_DIR=$SRC_BINARY_DIR" "BINARY_TOP=$BINARY_TOP" \
          "PRIMARY_PORT=$PRIMARY_PORT" "PRIMARY_HOST=$PRIMARY_HOST" "STANDBY_HOST=$STANDBY_HOST" \
          "SUBNET_CIDR=$SUBNET_CIDR"; do
    set_key "$TMP_OUT" "${kv%%=*}" "${kv#*=}"
done

# Storage layout: <MOUNT>/<cluster> keeps the template's derived *_TOP line (only the mount is set);
# any other path is written to the *_TOP line itself. Empty = mount "" = not used.
set_layout() {   # set_layout MOUNT_VAR TOP_VAR VALUE
    local mvar=$1 tvar=$2 val=${3%/}
    if [[ -z $val ]]; then
        set_key "$TMP_OUT" "$mvar" ""
        return 0
    fi
    set_key "$TMP_OUT" "$mvar" "$(dirname "$val")"
    if [[ $(basename "$val") != "$CLUSTER_DEFAULT" ]]; then set_key "$TMP_OUT" "$tvar" "$val"; fi
    return 0
}
set_layout DATA_MOUNT    DATA_TOP    "$DATA_TOP"
set_layout WAL_MOUNT     WAL_TOP     "$WAL_TOP"
set_layout ARCHIVE_MOUNT ARCHIVE_TOP "$ARCHIVE_TOP"
set_layout BACKUP_MOUNT  BACKUP_TOP  "$BACKUP_TOP"
set_layout LOG_MOUNT     LOG_TOP     "$LOG_TOP"

# Check BEFORE replacing anything, so a bad build never clobbers a good file
bash -n "$TMP_OUT" || die "Generated config has a syntax error - existing ${ENV_FILE} left untouched"

if [ -e "$ENV_FILE" ]; then
    BAK="${ENV_FILE}.bak_$(date +%F_%H%M%S)"
    cp -p "$ENV_FILE" "$BAK"
    warn "Previous file saved as $BAK"
fi
chmod 600 "$TMP_OUT"
mv -f "$TMP_OUT" "$ENV_FILE"

# =============================================================================
# 9. POST-CHECKS & REPORT (changes 16, 18)
# =============================================================================
log "Created ${ENV_FILE}"

SEC_TOP=$(grep -E '^[[:space:]]*(export[[:space:]]+)?SECURITY_TOP=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d "\"'" || true)
if [[ -n $SEC_TOP && ( $SEC_TOP == *'$DATA_TOP'* || $SEC_TOP == *'${DATA_TOP}'* || $SEC_TOP == "$DATA_TOP"/* ) ]]; then
    warn "SECURITY_TOP (${SEC_TOP}) is inside DATA_TOP (PGDATA): initdb needs an empty directory, and pg_basebackup/backups copy the SSL key and passphrase to every standby. Recommended: SECURITY_TOP=/etc/edb/ssl"
fi
if [[ -z $STANDBY_HOST ]]; then
    warn "STANDBY_HOST is empty - set it in ${ENV_FILE} before configuring replication"
fi
if ! grep -qE '^[[:space:]]*ENV_TAG="?(DEV|SIT|PAT|PROD)"?' "$ENV_FILE"; then
    warn "ENV_TAG is empty - set it in ${ENV_FILE} (DEV|SIT|PAT|PROD), or pass --tag to epas-base-build-db.sh"
fi
if (( ${#UNCONFIRMED[@]} > 0 )); then
    warn "Non-interactive run - these values were used without confirmation:"
    printf '    %s\n' "${UNCONFIRMED[@]}" >&2
    log_audit "Unconfirmed defaults in ${ENV_FILE}: ${UNCONFIRMED[*]}"
fi
if [[ -n $SEL ]]; then
    warn "An existing EPAS instance was detected - review DATA_TOP/SYSTEM_USER before running epas-base-build-root.sh / epas-base-build-db.sh"
fi
log_audit "Config generated: ${ENV_FILE} (EPAS ${EPAS_VERSION}, data ${DATA_TOP}, port ${PRIMARY_PORT}, run as ${RUN_AS})"
