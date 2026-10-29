#!/usr/bin/env bash
# ==============================================================================
# generate-site-env.sh  (formerly generate-env.sh)
#
# Detects the EPAS instance on this host (version, data directory, port, OS user,
# binaries, network), asks you to confirm each value, and writes conf/site.env
# built from conf/site.env.example.
#
# Usage: generate-site-env.sh [--instance <version|data dir>] [--force] [output_file]
#   --instance  choose the cluster when several are running (required when non-interactive)
#   --force     overwrite an existing output file without asking (old copy kept as .bak_<ts>)
#
# Needs: lib/common.sh (sets TOOLKIT_ROOT; may provide log/warn/die/log_audit).
#        Self-contained otherwise: instance detection is built in (_detect_epas_instances).
#
# ------------------------------------------------------------------------------
# CHANGES vs generate-env.sh (2026-10-29)
#  Bugs fixed
#   1. normalize_epas_version also reads stdin: the rpm and /usr/edb version fallbacks
#      piped into it and always came back empty.
#   2. An unusable version now reaches the FATAL message (set -e used to exit silently).
#   3. Running clusters are found by the built-in _detect_epas_instances (same logic as the
#      operations tool list_epas_instances.sh), which matches edb-postmaster; the old
#      '[p]ostgres' pattern never matched EPAS.
#   4. Port no longer relies on 'ss -p' (root/owner only, and it missed edb-postmaster).
#   5. Port follows server precedence: postgresql.auto.conf > conf.d/*.conf > postgresql.conf,
#      last setting wins; 'port=5444' without spaces is accepted.
#   6. PGDATA comes from 'systemctl show -p Environment' (unit + all drop-ins, quoted or not).
#   7. Fallback data path is /var/lib/edb/asNN/data (RPM default), not /var/lib/edb/data/asNN.
#   8. IP from the route's 'src' field; subnet from the kernel route (real prefix, not /24).
#  Detection
#   9. All running clusters are listed; you pick one (or use --instance).
#  10. Port order: running instance (postmaster.pid / -p) > config files > the single
#      /tmp/.s.PGSQL.* socket > 5444. Warns if the chosen port is already in use.
#  11. Shows who it runs as; warns when not root or the DB owner, because PGDATA (0700)
#      is then unreadable and values fall back to defaults.
#  12. Version fallback is the highest installed version, not the first one listed.
#      Choosing a version other than the running one drops that instance's defaults.
#  Safety
#  13. Every value is validated and written with printf %q, so nothing typed at a prompt
#      can execute when site.env is sourced.
#  14. STANDBY_HOST no longer defaults to 192.168.1.12; it is left empty and flagged.
#  15. Temp files are created next to the output (atomic mv, keeps SELinux context) and
#      removed on any exit; the new file is syntax-checked BEFORE it replaces the old one.
#  16. In a non-interactive run, every value used without confirmation is listed and audited.
#  Smaller
#  17. log/warn/die are defined only when lib/common.sh does not already provide them.
#  18. Unused SECURITY_TOP/SERVICE_NAME removed; warns if the template places SECURITY_TOP
#      inside DATA_TOP (initdb needs an empty PGDATA; pg_basebackup would copy it).
#  19. BINARY_TOP default: the running instance's binary tree when it is relocated, else
#      <storage root>/binary/asNN for /<root>/data/asNN layouts, else /usr/edb/asNN.
#  20. A summary is shown and confirmed before anything is written.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/common.sh"
: "${TOOLKIT_ROOT:?lib/common.sh did not set TOOLKIT_ROOT}"

# Use common.sh's helpers when it has them (change 17)
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

# Running EPAS clusters, one line each: VERSION|PGDATA|PORT|PID|OWNER|MANAGED_BY
# Embedded copy of the operations tool list_epas_instances.sh, so this build script
# has no external dependency. Keep the two copies in sync when changing either.
_detect_epas_instances() {
    local pid args data ver port owner mgr unit line
    local re_d='(^|[[:space:]])-D[[:space:]]*([^[:space:]]+)'
    local re_p='(^|[[:space:]])-p[[:space:]]*([0-9]+)'
    local -A seen=()

    # Pass 1: postmaster processes (covers systemd- and pg_ctl-started clusters)
    # Anchored: the program itself (argv[0]) must be the postmaster binary, so shells,
    # sudo or pg_ctl wrappers that merely mention it in their arguments don't match
    for pid in $(pgrep -f '^[^ ]*/bin/(edb-postmaster|edb-postgres|postmaster|postgres)( |$)' 2>/dev/null); do
        args=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || continue
        [[ $args =~ $re_d ]] || continue
        data=${BASH_REMATCH[2]}
        [[ -n ${seen[$data]:-} ]] && continue
        seen[$data]=1

        # Version: from the binary path (.../asNN/bin/...), else PG_VERSION
        if [[ ${args%% *} =~ /as([0-9]+)/bin/ ]]; then ver=${BASH_REMATCH[1]}
        else ver=$(cat "$data/PG_VERSION" 2>/dev/null || true); fi

        # Port: postmaster.pid (root/owner), else a -p on the command line
        port=$(sed -n 4p "$data/postmaster.pid" 2>/dev/null || true)
        if [[ -z $port && $args =~ $re_p ]]; then port=${BASH_REMATCH[2]}; fi

        owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
        # The cgroup tells us whether systemd started it (world-readable)
        unit=$(grep -oE '[^/]+\.service' "/proc/$pid/cgroup" 2>/dev/null | head -n1 || true)
        if [[ -n $unit && $unit != user@*.service && $unit != session-* ]]; then mgr="systemd:$unit"; else mgr="manual/pg_ctl"; fi

        echo "${ver:-?}|$data|${port:-?}|$pid|${owner:-?}|$mgr"
    done

    # Pass 2: active units whose process we could not see (e.g. /proc mounted with hidepid)
    if command -v systemctl &>/dev/null; then
        for unit in $(systemctl list-units 'edb-as-*' --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}'); do
            data=$(systemctl show -p Environment --value "$unit" 2>/dev/null | grep -oE '(^|[[:space:]])PGDATA=[^[:space:]]+' | tail -n1 || true)
            data=${data#*PGDATA=}
            [[ -z $data || -n ${seen[$data]:-} ]] && continue
            seen[$data]=1
            pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)
            port=$(sed -n 4p "$data/postmaster.pid" 2>/dev/null || true)
            ver=${unit//[!0-9]/}
            echo "${ver:-?}|$data|${port:-?}|${pid:-?}|$(systemctl show -p User --value "$unit" 2>/dev/null || true)|systemd:$unit"
        done
    fi
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
is_port()          { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_abs_path()      { [[ $1 == /* && $1 =~ ^[A-Za-z0-9._/+-]+$ && $1 != *..* ]]; }
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

# Network (change 8)
primary_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true
}
subnet_of() {
    [[ -n ${1:-} ]] || return 0
    ip -o -4 route show proto kernel scope link src "$1" 2>/dev/null | awk '{print $1; exit}' || true
}

# Installed versions, ascending (change 12)
installed_versions() {
    local d
    {
        for d in /usr/edb/as[0-9]*; do
            if [[ -d $d ]]; then echo "${d##*/as}"; fi
        done
        if command -v rpm &>/dev/null; then
            rpm -qa --qf '%{NAME}\n' 'edb-as*-server' 2>/dev/null | sed -nE 's/^edb-as-?([0-9]+)-server$/\1/p'
        fi
    } | grep -E '^[0-9]+$' | sort -un || true
}

# Port from config files, in server precedence; '' if nothing readable (change 5)
conf_port() {
    local d=$1 f q p=""
    local -a files=("$d/postgresql.conf")
    if [[ -d $d/conf.d ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(ls -1 "$d"/conf.d/*.conf 2>/dev/null | sort || true)
    fi
    files+=("$d/postgresql.auto.conf")
    for f in "${files[@]}"; do
        [[ -r $f ]] || continue
        q=$(sed -nE "s/^[[:space:]]*port[[:space:]]*=[[:space:]]*'?([0-9]+).*/\1/p" "$f" | tail -n1 || true)
        if [[ -n $q ]]; then p=$q; fi
    done
    echo "$p"
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
        IFS='|' read -r v d p pid o m <<< "${INSTANCES[$i]}"
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

DETECTED_VER="" DETECTED_DATA="" DETECTED_PORT="" DETECTED_PID="" DETECTED_OWNER="" DETECTED_MGR=""
RUNNING=false
RUN_BIN_HOME=""
if [[ -n $SEL ]]; then
    IFS='|' read -r DETECTED_VER DETECTED_DATA DETECTED_PORT DETECTED_PID DETECTED_OWNER DETECTED_MGR <<< "$SEL"
    # '?' means "could not be read" -> treat as unknown
    DETECTED_VER=${DETECTED_VER#\?}; DETECTED_PORT=${DETECTED_PORT#\?}
    DETECTED_PID=${DETECTED_PID#\?}; DETECTED_OWNER=${DETECTED_OWNER#\?}
    RUNNING=true
    log "Using running instance: EPAS ${DETECTED_VER:-?} at ${DETECTED_DATA} (${DETECTED_MGR})"
    # Binary tree the instance actually runs from (argv[0] is world-readable)
    if [[ $DETECTED_PID =~ ^[0-9]+$ && -r /proc/$DETECTED_PID/cmdline ]]; then
        argv0=$(tr '\0' '\n' 2>/dev/null < "/proc/$DETECTED_PID/cmdline" | head -n1 || true)
        argv0=${argv0%% *}   # some process titles hold all arguments in one string
        if [[ $argv0 == /*/bin/* ]]; then RUN_BIN_HOME=$(dirname "$(dirname "$argv0")"); fi
    fi
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
if [[ -z $DETECTED_DATA ]]; then
    if [[ -d /u001 ]]; then
        DETECTED_DATA="/u001/data/as${EPAS_VERSION}"
    elif [[ -d /var/lib/edb ]]; then
        DETECTED_DATA="/var/lib/edb/as${EPAS_VERSION}/data"
    else
        DETECTED_DATA="/u001/data/as${EPAS_VERSION}"
    fi
fi
prompt_var "Enter DATA_TOP directory" "$DETECTED_DATA" DATA_TOP is_abs_path \
           "absolute path using only letters, digits and . _ - + /"

if [[ -n $RUN_BIN_HOME && $RUN_BIN_HOME != "$SRC_BINARY_DIR" ]]; then
    DEFAULT_BIN_TOP=$RUN_BIN_HOME
elif [[ $DATA_TOP =~ ^(/[^/]+)/data/as[0-9]+(/data)?$ ]]; then
    DEFAULT_BIN_TOP="${BASH_REMATCH[1]}/binary/as${EPAS_VERSION}"
else
    DEFAULT_BIN_TOP=$SRC_BINARY_DIR
fi
prompt_var "Enter BINARY_TOP directory" "$DEFAULT_BIN_TOP" BINARY_TOP is_abs_path \
           "absolute path using only letters, digits and . _ - + /"

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
    DETECTED_PORT=$(conf_port "$DATA_TOP")
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
DEFAULT_IP=$(primary_ip)
DEFAULT_CIDR=$(subnet_of "$DEFAULT_IP")

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
          "SRC_BINARY_DIR=$SRC_BINARY_DIR" "BINARY_TOP=$BINARY_TOP" "DATA_TOP=$DATA_TOP" \
          "PRIMARY_PORT=$PRIMARY_PORT" "PRIMARY_HOST=$PRIMARY_HOST" "STANDBY_HOST=$STANDBY_HOST" \
          "SUBNET_CIDR=$SUBNET_CIDR"; do
    set_key "$TMP_OUT" "${kv%%=*}" "${kv#*=}"
done

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

SEC_TOP=$(grep -E '^[[:space:]]*(export[[:space:]]+)?SECURITY_TOP=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d "\"'" || true)
if [[ -n $SEC_TOP && ( $SEC_TOP == *'$DATA_TOP'* || $SEC_TOP == *'${DATA_TOP}'* || $SEC_TOP == "$DATA_TOP"/* ) ]]; then
    warn "SECURITY_TOP (${SEC_TOP}) is inside DATA_TOP: if DATA_TOP is the PGDATA itself, initdb needs it empty and pg_basebackup will copy it"
fi
if [[ -z $STANDBY_HOST ]]; then
    warn "STANDBY_HOST is empty - set it in ${ENV_FILE} before configuring replication"
fi
if (( ${#UNCONFIRMED[@]} > 0 )); then
    warn "Non-interactive run - these values were used without confirmation:"
    printf '    %s\n' "${UNCONFIRMED[@]}" >&2
    log_audit "Unconfirmed defaults in ${ENV_FILE}: ${UNCONFIRMED[*]}"
fi
if [[ -n $SEL ]]; then
    warn "An existing EPAS instance was detected - review DATA_TOP/SYSTEM_USER before running epas-base-build.sh"
fi
log_audit "Config generated: ${ENV_FILE} (EPAS ${EPAS_VERSION}, data ${DATA_TOP}, port ${PRIMARY_PORT}, run as ${RUN_AS})"
