#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/edb"
CONF_FILE="${CONF_DIR}/inventory.conf"

mkdir -p "$CONF_DIR"

# 1. Global Host Context
PRIMARY_HOST=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")
SUBNET_CIDR=$(ip route show default 2>/dev/null | awk '{print $3}' | cut -d'.' -f1-3).0/24
HOSTNAME=$(hostname -s 2>/dev/null || echo "localhost")

{
    echo "# Dynamic EPAS/PostgreSQL Inventory - Generated $(date -u)"
    echo ""
    echo "[HOST_METADATA]"
    echo "HOSTNAME=\"${HOSTNAME}\""
    echo "PRIMARY_HOST=\"${PRIMARY_HOST}\""
    echo "SUBNET_CIDR=\"${SUBNET_CIDR}\""
    echo ""
} > "$CONF_FILE"

# 2. Discover all running Postgres/EPAS instances via systemctl
SERVICES=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print $1}' | grep -E 'edb-as|postgresql' || true)

if [ -z "$SERVICES" ]; then
    echo "# No active EPAS or PostgreSQL systemd services detected." >> "$CONF_FILE"
    chmod 644 "$CONF_FILE"
    echo "Generated $CONF_FILE (No running services detected)."
    exit 0
fi

# 3. Iterate through detected services and capture details
for SVC in $SERVICES; do
    # Extract Service Name without .service suffix
    SVC_NAME="${SVC%.service}"

    # Extract Version
    VER=$(echo "$SVC_NAME" | grep -oP '\d+' || echo "Unknown")

    # Extract System User running the unit
    SVC_USER=$(systemctl show -p User "$SVC" 2>/dev/null | cut -d'=' -f2)
    SVC_USER="${SVC_USER:-enterprisedb}"

    # Extract PGDATA from systemctl Environment or ExecStart
    DATA_DIR=$(systemctl show "$SVC" --property=Environment 2>/dev/null | grep -oP 'PGDATA=\K[^ ]+' || true)
    if [ -z "$DATA_DIR" ]; then
        DATA_DIR=$(systemctl show "$SVC" --property=ExecStart 2>/dev/null | grep -oP '-D\s+\K[^\s;]+' || true)
    fi

    # Fallback PGDATA search in process table if systemctl properties are empty
    if [ -z "$DATA_DIR" ]; then
        DATA_DIR=$(ps aux | grep "[p]ostgres.*${SVC_NAME}" | grep -oP '-D\s+\K[^ ]+' | head -n1 || true)
    fi

    # Detect Port from postgresql.conf or running listening sockets
    PORT=""
    if [ -n "$DATA_DIR" ] && [ -f "${DATA_DIR}/postgresql.conf" ]; then
        PORT=$(grep -E "^\s*port\s*=" "${DATA_DIR}/postgresql.conf" 2>/dev/null | awk '{print $3}' | tr -d "'" || true)
    fi

    # Binary Directory
    BIN_DIR="/usr/edb/as${VER}/bin"
    if [ ! -d "$BIN_DIR" ]; then
        BIN_DIR="/usr/pgsql-${VER}/bin"
    fi

    # Append instance block to inventory file
    SECTION_HEADER=$(echo "${SVC_NAME}_${PORT:-5444}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')

    {
        echo "[${SECTION_HEADER}]"
        echo "SERVICE_NAME=\"${SVC_NAME}\""
        echo "EPAS_VERSION=\"${VER}\""
        echo "SYSTEM_USER=\"${SVC_USER}\""
        echo "PORT=\"${PORT:-Unknown}\""
        echo "DATA_TOP=\"${DATA_DIR:-Unknown}\""
        echo "BINARY_TOP=\"${BIN_DIR}\""
        echo ""
    } >> "$CONF_FILE"
done

chmod 644 "$CONF_FILE"
echo "Successfully generated $CONF_FILE"