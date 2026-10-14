#!/usr/bin/env bash
# Multi-Cluster EDB Failover Manager (EFM) installer/configurator for RHEL-family
# Supports multiple EFM clusters per node (e.g., EPAS 15 + EPAS 17)
# Usage: Run separately on each node (primary/standby/witness) for each cluster

set -Eeuo pipefail
umask 077

# Global defaults
declare -A DEFAULTS=(
    [EFM_VERSION]="53"
    [BIND_PORT]="7800"
    [ADMIN_PORT]="7801"
    [DB_PORT]="5444"
    [DB_USER]="efm"
    [DB_NAME]="edb"
    [DB_OWNER]="enterprisedb"
    [DB_BIN]="/usr/edb/as17/bin"
)

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
valid_cluster_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] && [[ "$1" != "efm" || "$1" == "efm" ]]; }

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

# Check root
[[ $EUID -eq 0 ]] || die "Run as root (sudo -i)"

# Detect OS
[[ -r /etc/os-release ]] || die "Cannot identify OS"
source /etc/os-release
[[ "${ID:-}" == "rhel" || "${ID_LIKE:-}" == *"rhel"* || "${ID:-}" == "rocky" || "${ID:-}" == "almalinux" || "${ID:-}" == "ol" ]] \
    || warn "Non-RHEL detected: ${PRETTY_NAME:-unknown}"

echo "============================================================"
echo " Multi-Cluster EFM Setup (EPAS 15/17+ compatible)"
echo "============================================================"

# Cluster identification
CLUSTER_NAME="$(ask 'Cluster name (unique per EFM cluster, e.g., efm15, efm17, prod-efm)' 'efm')"
valid_cluster_name "$CLUSTER_NAME" || die "Invalid cluster name. Use letters, numbers, underscore, hyphen only."

EFM_VERSION="$(ask 'EFM version (53=5.3, 54=5.4, etc.)' "${DEFAULTS[EFM_VERSION]}")"
[[ "$EFM_VERSION" =~ ^[0-9]{2}$ ]] || die "Use two-digit version (e.g., 53)"

# Calculate paths
EFM_VER_MAJOR="${EFM_VERSION:0:1}"
EFM_VER_MINOR="${EFM_VERSION:1:1}"
EFM_BASE="efm-${EFM_VER_MAJOR}.${EFM_VER_MINOR}"
EFM_PACKAGE="edb-efm${EFM_VERSION}"
EFM_ROOT="/etc/edb/${EFM_BASE}"
EFM_BIN="/usr/edb/${EFM_BASE}/bin"
EFM_LIB="/usr/edb/${EFM_BASE}/lib"

# Multi-cluster paths: /etc/edb/efm-5.3/efm15/ instead of /etc/edb/efm-5.3/
EFM_DIR="${EFM_ROOT}/${CLUSTER_NAME}"
PROPERTIES="${EFM_DIR}/${CLUSTER_NAME}.properties"
NODES="${EFM_DIR}/${CLUSTER_NAME}.nodes"
PID_FILE="/var/run/efm-${CLUSTER_NAME}.pid"
LOG_FILE="/var/log/edb/${EFM_BASE}/${CLUSTER_NAME}.log"

info "Cluster: $CLUSTER_NAME | EFM: $EFM_BASE | Dir: $EFM_DIR"

# Role selection
echo
echo "Select this server's role for cluster '$CLUSTER_NAME':"
echo "  1) Primary"
echo "  2) Standby" 
echo "  3) Witness"
ROLE="$(ask 'Enter 1, 2, or 3' '1')"
case "$ROLE" in
    1) IS_WITNESS=false; ROLE_NAME=primary ;;
    2) IS_WITNESS=false; ROLE_NAME=standby ;;
    3) IS_WITNESS=true; ROLE_NAME=witness ;;
    *) die "Invalid role" ;;
esac

# Network configuration - auto-suggest port offsets based on cluster name
# This helps avoid conflicts when running multiple clusters
SUGGESTED_BIND=$(( ${DEFAULTS[BIND_PORT]} + ( $(date +%s) % 100 ) ))
[[ "$CLUSTER_NAME" =~ 15$ ]] && SUGGESTED_BIND=7800
[[ "$CLUSTER_NAME" =~ 17$ ]] && SUGGESTED_BIND=7810
[[ "$CLUSTER_NAME" =~ 15 ]] && SUGGESTED_BIND=7800
[[ "$CLUSTER_NAME" =~ 17 ]] && SUGGESTED_BIND=7810

PRIMARY_IP="$(ask 'Primary server IP/address')"
STANDBY_IP="$(ask 'Standby server IP/address')"
WITNESS_IP="$(ask 'Witness server IP/address')"

BIND_IP="$(case "$ROLE" in 1) echo "$PRIMARY_IP";; 2) echo "$STANDBY_IP";; 3) echo "$WITNESS_IP";; esac)"
BIND_PORT="$(ask "EFM bind port for $CLUSTER_NAME (must be unique per node)" "$SUGGESTED_BIND")"
valid_port "$BIND_PORT" || die "Invalid port"

ADMIN_PORT="$(ask "EFM admin port (bind+1 recommended)" "$((BIND_PORT + 1))")"
valid_port "$ADMIN_PORT" || die "Invalid port"

# Database configuration
DB_PORT="$(ask 'EPAS/PostgreSQL port (5444=EPAS17, 5445=EPAS15, 5432=PG)' "${DEFAULTS[DB_PORT]}")"
valid_port "$DB_PORT" || die "Invalid DB port"

DB_USER="$(ask 'EFM database user' "${DEFAULTS[DB_USER]}")"
DB_NAME="$(ask 'Database name' "${DEFAULTS[DB_NAME]}")"

DB_OWNER=""
DB_SERVICE=""
DB_BIN=""
DB_DATA=""
DB_CONFIG=""

if [[ "$IS_WITNESS" == false ]]; then
    # Auto-detect EPAS version from port
    if [[ "$DB_PORT" == "5444" ]]; then
        DEFAULTS[DB_BIN]="/usr/edb/as17/bin"
        DEFAULTS[DB_OWNER]="enterprisedb"
    elif [[ "$DB_PORT" == "5445" ]]; then
        DEFAULTS[DB_BIN]="/usr/edb/as15/bin"
        DEFAULTS[DB_OWNER]="enterprisedb"
    elif [[ "$DB_PORT" == "5432" ]]; then
        DEFAULTS[DB_BIN]="/usr/pgsql-15/bin"
        DEFAULTS[DB_OWNER]="postgres"
    fi
    
    DB_OWNER="$(ask 'OS owner of database data directory' "${DEFAULTS[DB_OWNER]}")"
    DB_SERVICE="$(ask 'Database systemd service name (e.g., edb-as-17, edb-as-15, postgresql-15)' '')"
    DB_BIN="$(ask 'Database bin directory' "${DEFAULTS[DB_BIN]}")"
    DB_DATA="$(ask 'Database data directory (e.g., /var/lib/edb/as17/data)' '')"
    DB_CONFIG="$(ask 'Database config dir (blank if same as data)' '')"
fi

# Installation
info "Installing Java and $EFM_PACKAGE"
dnf install -y java-11-openjdk-headless || dnf install -y java-17-openjdk-headless
dnf install -y "$EFM_PACKAGE" || die "Package install failed. Check EDB repo configuration."

# Verify installation
[[ -x "${EFM_BIN}/efm" ]] || {
    FOUND_BIN="$(command -v efm || true)"
    [[ -n "$FOUND_BIN" ]] || die "efm binary not found"
    EFM_BIN="$(dirname "$FOUND_BIN")"
}

# Create multi-cluster directory structure
mkdir -p "$EFM_DIR" /var/log/edb/${EFM_BASE} /var/run
chmod 755 "$EFM_DIR"

# Handle existing config
if [[ -e "$PROPERTIES" ]]; then
    warn "Existing configuration found for cluster $CLUSTER_NAME"
    confirm "Backup and reconfigure" || die "Cancelled"
    stamp="$(date +%Y%m%d%H%M%S)"
    cp -a "$PROPERTIES" "${PROPERTIES}.bak.${stamp}"
    [[ ! -e "$NODES" ]] || cp -a "$NODES" "${NODES}.bak.${stamp}"
fi

# Initialize from templates
TEMPLATE="${EFM_ROOT}/efm.properties.in"
NODE_TEMPLATE="${EFM_ROOT}/efm.nodes.in"

[[ -f "$TEMPLATE" ]] || die "Template not found: $TEMPLATE"
cp "$TEMPLATE" "$PROPERTIES"

if [[ -f "$NODE_TEMPLATE" ]]; then 
    cp "$NODE_TEMPLATE" "$NODES"
else 
    : > "$NODES"
fi

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
set_prop "cluster.name" "$CLUSTER_NAME" "$PROPERTIES"

if [[ "$IS_WITNESS" == false ]]; then
    set_prop "db.service.owner" "$DB_OWNER" "$PROPERTIES"
    set_prop "db.bin" "$DB_BIN" "$PROPERTIES"
    [[ -z "$DB_DATA" ]] || set_prop "db.data.dir" "$DB_DATA" "$PROPERTIES"
    [[ -z "$DB_CONFIG" ]] || set_prop "db.config.dir" "$DB_CONFIG" "$PROPERTIES"
    [[ -z "$DB_SERVICE" ]] || set_prop "db.service.name" "$DB_SERVICE" "$PROPERTIES"
fi

chown -R efm:efm "$EFM_DIR"
chmod 600 "$PROPERTIES" "$NODES"

# Create systemd service instance
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_FILE="${SYSTEMD_DIR}/edb-efm-${EFM_VER_MAJOR}.${EFM_VER_MINOR}@.service"
SERVICE_NAME="edb-efm-${EFM_VER_MAJOR}.${EFM_VER_MINOR}@${CLUSTER_NAME}"

if [[ ! -f "$SERVICE_FILE" ]]; then
    info "Creating systemd template: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=EDB Failover Manager ${EFM_VER_MAJOR}.${EFM_VER_MINOR} - %i
After=network.target syslog.target
Wants=network.target

[Service]
Type=forking
User=efm
Group=efm
Environment="EFM_HOME=${EFM_ROOT}"
ExecStart=${EFM_BIN}/efm start %i
ExecStop=${EFM_BIN}/efm stop %i
ExecReload=${EFM_BIN}/efm reload %i
PIDFile=/var/run/efm-%i.pid
TimeoutSec=120
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi

# Summary
echo
echo "============================================================"
echo " Configuration Summary"
echo "============================================================"
echo "Cluster Name:  $CLUSTER_NAME"
echo "Role:          $ROLE_NAME"
echo "EFM Version:   $EFM_BASE"
echo "Config Dir:    $EFM_DIR"
echo "Properties:    $PROPERTIES"
echo "Nodes File:    $NODES"
echo "Service:       $SERVICE_NAME"
echo "Bind:          ${BIND_IP}:${BIND_PORT}"
echo "Admin Port:    $ADMIN_PORT"
echo "DB Port:       $DB_PORT"
[[ "$IS_WITNESS" == false ]] && echo "DB Owner:      $DB_OWNER"
echo "============================================================"

# Password encryption reminder
echo
echo "NEXT STEPS:"
echo "1. Set encrypted password:"
echo "   ${EFM_BIN}/efm encrypt ${CLUSTER_NAME} --from-properties ${PROPERTIES}"
echo "   Then add to ${PROPERTIES}: db.password.encrypted=<output>"
echo
echo "2. Configure firewall:"
echo "   firewall-cmd --permanent --add-port=${BIND_PORT}/tcp --add-port=${ADMIN_PORT}/tcp"
echo "   firewall-cmd --reload"
echo
echo "3. Start service:"
echo "   systemctl enable --now ${SERVICE_NAME}"
echo "   ${EFM_BIN}/efm cluster-status ${CLUSTER_NAME}"

if confirm "Start $CLUSTER_NAME now? (Only after all nodes are configured)"; then
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