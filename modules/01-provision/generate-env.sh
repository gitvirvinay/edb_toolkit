#!/usr/bin/env bash
set -euo pipefail

# Shared helpers (logger, die) and the repo location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

log() { echo -e "\e[32m[INFO]\e[0m $1"; }
warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

TEMPLATE="${TOOLKIT_ROOT}/conf/site.env.example"
ENV_FILE="${TOOLKIT_ROOT}/conf/site.env"
FORCE=0
usage() {
    cat <<USAGE
Usage: $0 [--force] [output_file]
Detects the EPAS version, data directory, OS user and port on this host (asks you to confirm each)
and writes a config file built from conf/site.env.example with the detected values filled in.
Default output: conf/site.env in the repo. An existing file is never overwritten silently:
you are asked first, or use --force (the old file is kept as <file>.bak_<timestamp>).
USAGE
    exit 0
}
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --force)   FORCE=1; shift ;;
        -*)        die "Unknown option: $1 (see --help)" ;;
        *)         ENV_FILE="$1"; shift ;;
    esac
done
[ -f "$TEMPLATE" ] || die "Template not found: $TEMPLATE"

# Normalize any version-ish string to a bare number.
# Handles: 15 | as15 | edb-as15 | edb-as-15 | edb-as15-server |
#          edb-as-15.service | edb-as-15-server.service | /usr/edb/as15
normalize_epas_version() {
    echo "$1" | grep -oE '[0-9]+' | head -n1
}

# Helper to prompt user interactively with a default value
prompt_var() {
    local prompt_text="$1"
    local default_val="$2"
    local result_var="$3"

    local input_val=""
    if [ -t 0 ]; then
        read -rp "${prompt_text} [default: ${default_val}]: " input_val
    fi
    # printf -v assigns the text literally (the old 'eval' could execute quotes or $(...) typed in)
    printf -v "$result_var" '%s' "${input_val:-$default_val}"
}

# =============================================================================
# RUNNING EPAS DETECTION
#
# Detection order (first hit wins):
#   1. systemd: an active edb-as-<N>.service -> version from unit name,
#      data dir from Environment=PGDATA (drop-in or unit file)
#   2. Process table: postgres/edb postmaster with -D <datadir> -> version
#      from PG_VERSION file, data dir from the -D argument
#   3. Postmaster PID file: <datadir>/postmaster.pid with a live PID
# =============================================================================

DETECTED_VER=""
DETECTED_DATA_TOP=""
DETECTED_PORT=""
RUNNING="false"

# --- 1. systemd ----------------------------------------------------------------
if command -v systemctl &>/dev/null; then
    # Look for ACTIVE edb-as-<N> services (failed/inactive units are ignored)
    ACTIVE_SVC=$(systemctl list-units --type=service --state=running,active \
                 --no-legend --no-pager 2>/dev/null \
                 | awk '/edb-as-?[0-9]+.*\.service/ {print $1; exit}' || true)

    if [[ -n "$ACTIVE_SVC" ]]; then
        RUNNING="true"
        log "Detected ACTIVE EPAS service: $ACTIVE_SVC"
        DETECTED_VER=$(normalize_epas_version "$ACTIVE_SVC")

        # Pull PGDATA from the drop-in override first, then the unit file
        DROPIN="/etc/systemd/system/${ACTIVE_SVC%.service}.service.d/override.conf"
        UNIT_FILE=$(systemctl show -p FragmentPath --value "$ACTIVE_SVC" 2>/dev/null || true)

        for f in "$DROPIN" "$UNIT_FILE"; do
            [[ -n "$DETECTED_DATA_TOP" || ! -f "$f" ]] && continue
            DETECTED_DATA_TOP=$(grep -oP 'Environment=PGDATA=\K[^ ]+' "$f" 2>/dev/null | head -n1 || true)
        done

        # Fallback: environment of the actual postmaster process
        if [[ -z "$DETECTED_DATA_TOP" ]]; then
            POSTMASTER_PID=$(systemctl show -p MainPID --value "$ACTIVE_SVC" 2>/dev/null || echo 0)
            if [[ "$POSTMASTER_PID" =~ ^[0-9]+$ ]] && [[ "$POSTMASTER_PID" -gt 1 ]]; then
                DETECTED_DATA_TOP=$(tr '\0' '\n' < "/proc/${POSTMASTER_PID}/environ" 2>/dev/null \
                                    | grep -oP '^PGDATA=\K.*' || true)
            fi
        fi
    fi
fi

# --- 2. Process table ------------------------------------------------------------
if [[ -z "$DETECTED_DATA_TOP" ]] && command -v ps &>/dev/null; then
    # postgres postmaster processes always carry -D <datadir>; [p]ostgres avoids
    # matching grep itself.
    DETECTED_DATA_TOP=$(ps -eo args --no-headers 2>/dev/null \
                        | grep '[p]ostgres' \
                        | grep -oP '(?<=-D )\S+' \
                        | head -n1 || true)
    if [[ -n "$DETECTED_DATA_TOP" ]]; then
        RUNNING="true"
        log "Detected running postmaster with PGDATA=${DETECTED_DATA_TOP}"
        # Version from PG_VERSION file inside the data dir (most reliable)
        if [[ -f "${DETECTED_DATA_TOP}/PG_VERSION" ]]; then
            DETECTED_VER=$(normalize_epas_version "$(cat "${DETECTED_DATA_TOP}/PG_VERSION" 2>/dev/null)")
        fi
    fi
fi

# --- 3. Postmaster PID files -------------------------------------------------------
if [[ -z "$DETECTED_DATA_TOP" ]]; then
    for pidfile in /u001/data/as*/postmaster.pid /var/lib/edb/as*/data/postmaster.pid; do
        [[ -f "$pidfile" ]] || continue
        pid=$(head -n1 "$pidfile" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            DETECTED_DATA_TOP=$(dirname "$pidfile")
            RUNNING="true"
            [[ -f "${DETECTED_DATA_TOP}/PG_VERSION" ]] && \
                DETECTED_VER=$(normalize_epas_version "$(cat "${DETECTED_DATA_TOP}/PG_VERSION" 2>/dev/null)")
            break
        fi
    done
fi

# --- Installed-package fallback (version only) ---------------------------------------
if [[ -z "${DETECTED_VER}" ]] && command -v rpm &>/dev/null; then
    DETECTED_VER=$(rpm -qa | grep -E '^edb-as-?[0-9]+-server' \
                   | head -n1 | normalize_epas_version || true)
fi

if [[ -z "${DETECTED_VER}" && -d "/usr/edb" ]]; then
    DETECTED_VER=$(ls -d /usr/edb/as* 2>/dev/null | grep -E 'as[0-9]+$' \
                   | head -n1 | normalize_epas_version || true)
fi

[[ "$RUNNING" == "true" ]] && warn "Running EPAS instance detected - values below will default to the LIVE configuration"

# ==========================================
# 1. EPAS VERSION PROMPT
# ==========================================
prompt_var "Enter EPAS Version" "${DETECTED_VER:-17}" "EPAS_VERSION"
EPAS_VERSION=$(normalize_epas_version "$EPAS_VERSION")
[[ "$EPAS_VERSION" =~ ^[0-9]+$ ]] || { echo "FATAL: could not derive a numeric EPAS version from '${EPAS_VERSION}'"; exit 1; }
log "Using EPAS version: ${EPAS_VERSION}"
SRC_BINARY_DIR="/usr/edb/as${EPAS_VERSION}"

# ==========================================
# 2. DATA_TOP & BINARY_TOP PROMPT
# ==========================================
if [[ -z "$DETECTED_DATA_TOP" ]]; then
    if [ -d "/u001" ]; then
        BASE_STORAGE="/u001"
    elif [ -d "/var/lib/edb" ]; then
        BASE_STORAGE="/var/lib/edb"
    else
        BASE_STORAGE="/u001"
    fi
    DETECTED_DATA_TOP="${BASE_STORAGE}/data/as${EPAS_VERSION}"
fi

prompt_var "Enter DATA_TOP directory" "$DETECTED_DATA_TOP" "DATA_TOP"

DEFAULT_BIN_TOP="$(dirname "$(dirname "$DATA_TOP")")/binary/as${EPAS_VERSION}"
prompt_var "Enter BINARY_TOP directory" "$DEFAULT_BIN_TOP" "BINARY_TOP"

SECURITY_TOP="${DATA_TOP}/security"
SERVICE_NAME="edb-as-${EPAS_VERSION}"

# ==========================================
# 3. SYSTEM_USER & SYSTEM_GROUP PROMPT
# ==========================================
DETECTED_USER="enterprisedb"
if id "enterprisedb" &>/dev/null; then
    DETECTED_USER="enterprisedb"
elif id "postgres" &>/dev/null; then
    DETECTED_USER="postgres"
fi

# If we found a running postmaster, default the OS user to its owner
if [[ "$RUNNING" == "true" && -n "$DETECTED_DATA_TOP" && -f "${DETECTED_DATA_TOP}/postmaster.pid" ]]; then
    PID_FROM_FILE=$(head -n1 "${DETECTED_DATA_TOP}/postmaster.pid" 2>/dev/null || true)
    if [[ "$PID_FROM_FILE" =~ ^[0-9]+$ ]] && kill -0 "$PID_FROM_FILE" 2>/dev/null; then
        OWNER=$(ps -o user= -p "$PID_FROM_FILE" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$OWNER" ]] && DETECTED_USER="$OWNER"
    fi
fi

prompt_var "Enter System User" "$DETECTED_USER" "SYSTEM_USER"

DETECTED_GROUP=$(id -gn "$SYSTEM_USER" 2>/dev/null || echo "$SYSTEM_USER")
prompt_var "Enter System Group" "$DETECTED_GROUP" "SYSTEM_GROUP"

# ==========================================
# 4. PRIMARY_PORT DETECT & PROMPT
# ==========================================
if [[ -z "$DETECTED_PORT" ]] && command -v ss &>/dev/null; then
    DETECTED_PORT=$(ss -tulpn 2>/dev/null \
                    | grep -E 'postgres|edb-as' \
                    | awk '{print $5}' | sed -E 's/.*://' | head -n1 || true)
fi

if [[ -z "$DETECTED_PORT" && -f "${DATA_TOP}/postgresql.conf" ]]; then
    DETECTED_PORT=$(grep -rE "^\s*port\s*=" "${DATA_TOP}/postgresql.conf" "${DATA_TOP}/conf.d/" 2>/dev/null \
                    | head -n1 | awk '{print $3}' | tr -d "'" || true)
fi

prompt_var "Enter Primary Database Port" "${DETECTED_PORT:-5444}" "PRIMARY_PORT"

# ==========================================
# 5. NETWORK CONTEXT DETECT & PROMPT
# ==========================================
DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")
DEFAULT_CIDR=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d'.' -f1-3).0/24

prompt_var "Enter Primary Host IP" "$DEFAULT_IP" "PRIMARY_HOST"
prompt_var "Enter Subnet CIDR" "$DEFAULT_CIDR" "SUBNET_CIDR"
prompt_var "Enter Standby Host IP" "192.168.1.12" "STANDBY_HOST"

# ==========================================
# 6. WRITE OUT the config, built from conf/site.env.example
# ==========================================
if [ -e "$ENV_FILE" ]; then
    if [ "$FORCE" -ne 1 ]; then
        if [ -t 0 ]; then
            read -rp "$ENV_FILE already exists. Overwrite it (old copy kept as .bak)? (y/N): " ow
            [[ "$ow" =~ ^[Yy]$ ]] || die "Not overwritten. Use another output file or --force."
        else
            die "$ENV_FILE already exists. Not overwriting (use --force)."
        fi
    fi
    BAK="${ENV_FILE}.bak_$(date +%F_%H%M%S)"
    cp -p "$ENV_FILE" "$BAK"
    warn "Previous file saved as $BAK"
fi
mkdir -p "$(dirname "$ENV_FILE")"

# set_key FILE KEY VALUE : replace the first 'KEY=' line (or append it) with KEY="VALUE"
set_key() {
    local f="$1" k="$2" v="$3" tmp
    tmp=$(mktemp)
    awk -v k="$k" -v v="$v" 'BEGIN{d=0} !d && $0 ~ "^"k"=" {print k"=\""v"\""; d=1; next} {print} END{if(!d) print k"=\""v"\""}' "$f" > "$tmp"
    cat "$tmp" > "$f"; rm -f "$tmp"
}

TMP_OUT=$(mktemp)
{
    echo "# Generated by generate-env.sh on $(date -u '+%F %T') UTC on host $(hostname -s 2>/dev/null || hostname)"
    echo "# from conf/site.env.example with detected/confirmed values. Review before use."
    cat "$TEMPLATE"
} > "$TMP_OUT"
for kv in "EPAS_VERSION=$EPAS_VERSION" "SYSTEM_USER=$SYSTEM_USER" "SYSTEM_GROUP=$SYSTEM_GROUP" \
          "SRC_BINARY_DIR=$SRC_BINARY_DIR" "BINARY_TOP=$BINARY_TOP" "DATA_TOP=$DATA_TOP" "PRIMARY_PORT=$PRIMARY_PORT" \
          "PRIMARY_HOST=$PRIMARY_HOST" "STANDBY_HOST=$STANDBY_HOST" "SUBNET_CIDR=$SUBNET_CIDR"; do
    set_key "$TMP_OUT" "${kv%%=*}" "${kv#*=}"
done
mv "$TMP_OUT" "$ENV_FILE"
chmod 600 "$ENV_FILE"
bash -n "$ENV_FILE" || die "Generated file has a syntax error: $ENV_FILE"

log "Successfully created $ENV_FILE with configuration:"
echo "  - EPAS Version : $EPAS_VERSION"
echo "  - System User  : $SYSTEM_USER:$SYSTEM_GROUP"
echo "  - Data Directory : $DATA_TOP"
echo "  - Binary Directory : $BINARY_TOP"
echo "  - Primary Port : $PRIMARY_PORT"
echo "  - Primary / Standby : $PRIMARY_HOST / $STANDBY_HOST  (subnet $SUBNET_CIDR)"
echo "  Other settings (EFM, STANZA, VIP, TDE) are the template defaults - review them in $ENV_FILE."
[[ "$RUNNING" == "true" ]] && warn "Existing EPAS instance was detected - review DATA_TOP/SYSTEM_USER before running epas-base-build.sh"
log_audit "Config generated: $ENV_FILE (EPAS ${EPAS_VERSION}, data ${DATA_TOP}, port ${PRIMARY_PORT})"
