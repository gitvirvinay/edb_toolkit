#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-deploy.env}"

log() { echo -e "\e[32m[INFO]\e[0m $1"; }

# Helper to prompt user interactively with a default value
prompt_var() {
    local prompt_text="$1"
    local default_val="$2"
    local result_var="$3"

    # Only prompt if running in an interactive terminal (TTY)
    if [ -t 0 ]; then
        read -rp "${prompt_text} [default: ${default_val}]: " input_val
        eval "${result_var}=\"${input_val:-$default_val}\""
    else
        eval "${result_var}=\"${default_val}\""
    fi
}

# ==========================================
# 1. EPAS VERSION DETECT & PROMPT
# ==========================================
DETECTED_VER=""
if command -v rpm &>/dev/null; then
    DETECTED_VER=$(rpm -qa | grep -E '^edb-as[0-9]+-server' | sed -E 's/edb-as([0-9]+)-server.*/\1/' | head -n1 || true)
fi

if [ -z "${DETECTED_VER}" ] && [ -d "/usr/edb" ]; then
    DETECTED_VER=$(ls -d /usr/edb/as* 2>/dev/null | grep -E 'as[0-9]+$' | sed 's/.*as//' | sort -V | tail -n1 || true)
fi

prompt_var "Enter EPAS Version" "${DETECTED_VER:-17}" "EPAS_VERSION"
SRC_BINARY_DIR="/usr/edb/as${EPAS_VERSION}"

# ==========================================
# 2. DATA_TOP & BINARY_TOP DETECT & PROMPT
# ==========================================
# Check running process for PGDATA if active
DETECTED_DATA_TOP=""
if command -v psself &>/dev/null || command -v pg_rep &>/dev/null || pgrep -f "postgres" &>/dev/null; then
    DETECTED_DATA_TOP=$(ps aux | grep '[p]ostgres.*-D' | sed -E 's/.*-D ([^ ]+).*/\1/' | head -n1 || true)
fi

# Fallback base storage check
if [ -z "$DETECTED_DATA_TOP" ]; then
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

# Infer BINARY_TOP from parent directory of DATA_TOP or default pattern
DEFAULT_BIN_TOP="$(dirname "$(dirname "$DATA_TOP")")/binary/as${EPAS_VERSION}"
prompt_var "Enter BINARY_TOP directory" "${DEFAULT_BIN_TOP#/}" "BINARY_TOP"

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

prompt_var "Enter System User" "$DETECTED_USER" "SYSTEM_USER"

# Auto-detect group for the selected user
DETECTED_GROUP=$(id -gn "$SYSTEM_USER" 2>/dev/null || echo "$SYSTEM_USER")
prompt_var "Enter System Group" "$DETECTED_GROUP" "SYSTEM_GROUP"

# ==========================================
# 4. PRIMARY_PORT DETECT & PROMPT
# ==========================================
DETECTED_PORT=""
if command -v ss &>/dev/null; then
    DETECTED_PORT=$(ss -tulpn 2>/dev/null | grep -E 'postgres|edb-as' | awk '{print $5}' | sed -E 's/.*://' | head -n1 || true)
fi

if [ -z "$DETECTED_PORT" ] && [ -f "${DATA_TOP}/postgresql.conf" ]; then
    DETECTED_PORT=$(grep -E "^\s*port\s*=" "${DATA_TOP}/postgresql.conf" 2>/dev/null | awk '{print $3}' | tr -d "'" || true)
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
# 6. WRITE OUT deploy.env
# ==========================================
cat << EOF > "$ENV_FILE"
# EPAS Version -- generated dynamically $(date -u)
EPAS_VERSION=${EPAS_VERSION}
PRIMARY_PORT=${PRIMARY_PORT}
BINARY_TOP=${BINARY_TOP}
DATA_TOP=${DATA_TOP}
SECURITY_TOP="${SECURITY_TOP}"
SERVICE_NAME=${SERVICE_NAME}
SYSTEM_USER=${SYSTEM_USER}
SYSTEM_GROUP=${SYSTEM_GROUP}
SRC_BINARY_DIR=${SRC_BINARY_DIR}
PRIMARY_HOST="${PRIMARY_HOST}"
STANDBY_HOST="${STANDBY_HOST}"
SUBNET_CIDR="${SUBNET_CIDR}"
REP_USER="repuser"
USE_REPLICATION_SLOT="false"

# Replication slot name
CURRENT_HOST="\$(hostname -s 2>/dev/null || echo "localhost")"
REP_SLOT_NAME="standby_\$(echo "\${CURRENT_HOST}")"

# TDE Configuration
TDE_WRAP_CMD="openssl enc -e -aes-128-cbc -pbkdf2 -pass pass:CHANGEME-USE-VAULT-OR-ENV-VAR -out %p"
TDE_UNWRAP_CMD="openssl enc -d -aes-128-cbc -pbkdf2 -pass pass:CHANGEME-USE-VAULT-OR-ENV-VAR -in %p"
EOF

chmod 600 "$ENV_FILE"

log "Successfully created $ENV_FILE with configuration:"
echo "  - EPAS Version : $EPAS_VERSION"
echo "  - System User  : $SYSTEM_USER:$SYSTEM_GROUP"
echo "  - Data Directory : $DATA_TOP"
echo "  - Binary Directory : $BINARY_TOP"
echo "  - Primary Port : $PRIMARY_PORT"
echo "  - Primary Host : $PRIMARY_HOST"