#!/usr/bin/env bash
# Multi-Cluster EFM Setup - Flat Structure
# Configs: /etc/edb/efm-5.3/efm15.properties, efm15.nodes
# Services: edb-efm-efm15.service, edb-efm-efm17.service

set -Eeuo pipefail
umask 077

die() { echo "ERROR: $*" >&2; exit 1; }
info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
ask() {
    local prompt="$1" default="${2:-}" answer
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer
        printf '%s' "${answer:-$default}"
    else
        while :; do
            read -r -p "$prompt: " answer
            [[ -n "$answer" ]] && { printf '%s' "$answer"; return; }
            echo "A value is required."
        done
    fi
}
confirm() {
    local prompt="$1" answer
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }

set_prop() {
    local key="$1" value="$2" file="$3" tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" '
        BEGIN { found=0 }
        $0 ~ "^[[:space:]#]*" k "[[:space:]]*=" {
            if (!found) { print k "=" v; found=1 }
            next
        }
        { print }
        END { if (!found) print k "=" v }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)"
[[ -r /etc/os-release ]] || die "Cannot identify OS"
source /etc/os-release
[[ "${ID:-}" == "rhel" || "${ID_LIKE:-}" == *"rhel"* || "${ID:-}" == "rocky" || "${ID:-}" == "almalinux" || "${ID:-}" == "ol" ]] \
    || warn "Non-RHEL detected: ${PRETTY_NAME:-unknown}"

echo "============================================================"
echo " Multi-Cluster EFM Setup (Flat Structure)"
echo "============================================================"

# Cluster identification
CLUSTER_NAME="$(ask 'Cluster name (e.g., efm15, efm17, prod)' 'efm')"
[[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid cluster name"

EFM_VERSION="$(ask 'EFM version (53=5.3, 54=5.4)' '53')"
[[ "$EFM_VERSION" =~ ^[0-9]{2}$ ]] || die "Two digits required"

EFM_VER_MAJOR="${EFM_VERSION:0:1}"
EFM_VER_MINOR="${EFM_VERSION:1:1}"
EFM_BASE="efm-${EFM_VER_MAJOR}.${EFM_VER_MINOR}"
EFM_PACKAGE="edb-efm${EFM_VERSION}"
EFM_ROOT="/etc/edb/${EFM_BASE}"
EFM_BIN="/usr/edb/${EFM_BASE}/bin"

# FLAT STRUCTURE: /etc/edb/efm-5.3/efm15.properties
PROPERTIES="${EFM_ROOT}/${CLUSTER_NAME}.properties"
NODES="${EFM_ROOT}/${CLUSTER_NAME}.nodes"
PID_FILE="/var/run/efm-${CLUSTER_NAME}.pid"
LOG_FILE="/var/log/edb/${EFM_BASE}/${CLUSTER_NAME}.log"

info "Cluster: $CLUSTER_NAME | EFM: $EFM_BASE | Config: $PROPERTIES"

# Role selection
echo
echo "Select role for '$CLUSTER_NAME':"
echo "  1) Primary  2) Standby  3) Witness"
ROLE="$(ask 'Enter 1, 2, or 3' '1')"
case "$ROLE" in
    1) IS_WITNESS=false; ROLE_NAME=primary ;;
    2) IS_WITNESS=false; ROLE_NAME=standby ;;
    3) IS_WITNESS=true; ROLE_NAME=witness ;;
    *) die "Invalid role" ;;
esac

# Network
PRIMARY_IP="$(ask 'Primary IP')"
STANDBY_IP="$(ask 'Standby IP')"
WITNESS_IP="$(ask 'Witness IP')"

BIND_IP="$(case "$ROLE" in 1) echo "$PRIMARY_IP";; 2) echo "$STANDBY_IP";; 3) echo "$WITNESS_IP";; esac)"

# Auto-suggest ports based on cluster name
SUGGESTED_BIND=7800
[[ "$CLUSTER_NAME" =~ 17 ]] && SUGGESTED_BIND=7810
[[ "$CLUSTER_NAME" =~ 15 ]] && SUGGESTED_BIND=7800

BIND_PORT="$(ask "EFM bind port" "$SUGGESTED_BIND")"
valid_port "$BIND_PORT" || die "Invalid port"

ADMIN_PORT="$(ask "EFM admin port" "$((BIND_PORT + 1))")"
valid_port "$ADMIN_PORT" || die "Invalid port"

# Database
DB_PORT="$(ask 'EPAS/PostgreSQL port (5444=EPAS17, 5445=EPAS15)' '5444')"
valid_port "$DB_PORT" || die "Invalid DB port"

DB_USER="$(ask 'EFM database user' 'efm')"
DB_NAME="$(ask 'Database name' 'edb')"

DB_OWNER=""
DB_SERVICE=""
DB_BIN=""
DB_DATA=""
DB_CONFIG=""

if [[ "$IS_WITNESS" == false ]]; then
    # Auto-detect paths
    if [[ "$DB_PORT" == "5444" ]]; then
        DB_BIN_DEFAULT="/usr/edb/as17/bin"
        DB_OWNER_DEFAULT="enterprisedb"
    elif [[ "$DB_PORT" == "5445" ]]; then
        DB_BIN_DEFAULT="/usr/edb/as15/bin"
        DB_OWNER_DEFAULT="enterprisedb"
    else
        DB_BIN_DEFAULT="/usr/pgsql-${DB_PORT}/bin"
        DB_OWNER_DEFAULT="postgres"
    fi
    
    DB_OWNER="$(ask 'DB data directory owner' "$DB_OWNER_DEFAULT")"
    DB_SERVICE="$(ask 'DB systemd service (e.g., edb-as-17)' '')"
    DB_BIN="$(ask 'DB bin directory' "$DB_BIN_DEFAULT")"
    DB_DATA="$(ask 'DB data directory' '')"
    DB_CONFIG="$(ask 'DB config dir (blank=same as data)' '')"
fi

# Install
info "Installing $EFM_PACKAGE"
dnf install -y java-11-openjdk-headless || dnf install -y java-17-openjdk-headless
dnf install -y "$EFM_PACKAGE" || die "Package install failed"

[[ -x "${EFM_BIN}/efm" ]] || die "efm binary not found at ${EFM_BIN}"

# Backup existing
if [[ -e "$PROPERTIES" ]]; then
    warn "Existing config found: $PROPERTIES"
    confirm "Backup and overwrite" || die "Cancelled"
    stamp="$(date +%Y%m%d%H%M%S)"
    cp -a "$PROPERTIES" "${PROPERTIES}.bak.${stamp}"
    [[ ! -e "$NODES" ]] || cp -a "$NODES" "${NODES}.bak.${stamp}"
fi

# Create from templates
TEMPLATE="${EFM_ROOT}/efm.properties.in"
NODE_TEMPLATE="${EFM_ROOT}/efm.nodes.in"

[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"
cp "$TEMPLATE" "$PROPERTIES"
[[ -f "$NODE_TEMPLATE" ]] && cp "$NODE_TEMPLATE" "$NODES" || : > "$NODES"

# Build nodes file
printf '%s:%s\n%s:%s\n%s:%s\n' \
    "$PRIMARY_IP" "$BIND_PORT" \
    "$STANDBY_IP" "$BIND_PORT" \
    "$WITNESS_IP" "$BIND_PORT" > "$NODES"

# Configure properties
set_prop "bind.address" "${BIND_IP}:${BIND_PORT}" "$PROPERTIES"
set_prop "admin.port" "$ADMIN_PORT" "$PROPERTIES"
set_prop "is.witness" "$IS_WITNESS" "$PROPERTIES"
set_prop "db.port" "$DB_PORT" "$PROPERTIES"
set_prop "db.user" "$DB_USER" "$PROPERTIES"
set_prop "db.database" "$DB_NAME" "$PROPERTIES"
set_prop "auto.allow.hosts" "false" "$PROPERTIES"
set_prop "stable.nodes.file" "true" "$PROPERTIES"
set_prop "pid.file" "$PID_FILE" "$PROPERTIES"
set_prop "log.file" "$LOG_FILE" "$PROPERTIES"

if [[ "$IS_WITNESS" == false ]]; then
    set_prop "db.service.owner" "$DB_OWNER" "$PROPERTIES"
    set_prop "db.bin" "$DB_BIN" "$PROPERTIES"
    [[ -z "$DB_DATA" ]] || set_prop "db.data.dir" "$DB_DATA" "$PROPERTIES"
    [[ -z "$DB_CONFIG" ]] || set_prop "db.config.dir" "$DB_CONFIG" "$PROPERTIES"
    [[ -z "$DB_SERVICE" ]] || set_prop "db.service.name" "$DB_SERVICE" "$PROPERTIES"
fi

chown efm:efm "$PROPERTIES" "$NODES"
chmod 600 "$PROPERTIES" "$NODES"

# Create individual systemd service (FLAT STRUCTURE)
SERVICE_NAME="edb-efm-${CLUSTER_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

info "Creating service: $SERVICE_NAME"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=EDB Failover Manager ${EFM_BASE} - ${CLUSTER_NAME}
After=network.target syslog.target

[Service]
Type=forking
User=efm
Group=efm
ExecStart=${EFM_BIN}/efm start ${CLUSTER_NAME} --properties ${PROPERTIES}
ExecStop=${EFM_BIN}/efm stop ${CLUSTER_NAME}
ExecReload=${EFM_BIN}/efm reload ${CLUSTER_NAME}
PIDFile=${PID_FILE}
TimeoutSec=120
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# Summary
echo
echo "============================================================"
echo " Configuration Complete"
echo "============================================================"
echo "Cluster:       $CLUSTER_NAME"
echo "Role:          $ROLE_NAME"
echo "Properties:    $PROPERTIES"
echo "Nodes:         $NODES"
echo "Service:       $SERVICE_NAME.service"
echo "Bind:          ${BIND_IP}:${BIND_PORT}"
echo "Admin Port:    $ADMIN_PORT"
echo "DB Port:       $DB_PORT"
echo "============================================================"

echo
echo "NEXT STEPS:"
echo "1. Set encrypted password:"
echo "   ${EFM_BIN}/efm encrypt ${CLUSTER_NAME} --from-properties ${PROPERTIES}"
echo "   Add to ${PROPERTIES}: db.password.encrypted=<output>"
echo
echo "2. Configure firewall:"
echo "   firewall-cmd --permanent --add-port=${BIND_PORT}/tcp --add-port=${ADMIN_PORT}/tcp"
echo "   firewall-cmd --reload"
echo
echo "3. Start service:"
echo "   systemctl enable --now ${SERVICE_NAME}"
echo "   ${EFM_BIN}/efm cluster-status ${CLUSTER_NAME}"

if confirm "Start $CLUSTER_NAME now?"; then
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    sleep 2
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    echo
    "${EFM_BIN}/efm" cluster-status "$CLUSTER_NAME" || true
fi

echo
echo "Logs: journalctl -u ${SERVICE_NAME} -f"
echo "Done."