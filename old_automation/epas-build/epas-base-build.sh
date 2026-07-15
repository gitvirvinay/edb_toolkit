#!/bin/bash
# ==============================================================================
# GENERIC MULTI-VERSION EPAS CLUSTER LAYOUT & CORE INITIALIZATION
# sudo ./epas-base-build.sh --env dev-as17.env
# Compatibility: EPAS 15, 17, 18+ (RHEL/Rocky Linux Platforms)
# ==============================================================================
set -e

log() { echo -e "\n=== $1 ==="; }

# --- Step 1: Environment Parameter Hydration ---
if [ "$1" == "--env" ]; then
    shift
fi

if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_deploy.env]"
    exit 1
fi
source "$1"

# Validate that essential parameters were loaded
if [ -z "$EPAS_VERSION" ] || [ -z "$BINARY_TOP" ] || [ -z "$DATA_TOP" ]; then
    echo "[ERROR] Missing critical configuration variables in env file."
    exit 1
fi

log "START: EPAS ${EPAS_VERSION} Enterprise Build Infrastructure"

# ==============================================================================
# PHASE 1: REPOSITORY INSTALLATION & SYSTEMD SETUP
# ==============================================================================
log "Installing EPAS ${EPAS_VERSION} Packages"
PACKAGE_NAME="edb-as${EPAS_VERSION}-server"

if ! dnf list installed "$PACKAGE_NAME" &>/dev/null; then
    dnf install -y "$PACKAGE_NAME"
    echo "Package $PACKAGE_NAME successfully installed."
else
    echo "Package $PACKAGE_NAME already installed. Skipping dnf step."
fi

log "Creating Custom Systemd Service Unit"
SOURCE_SERVICE="/usr/lib/systemd/system/edb-as-${EPAS_VERSION}.service"
TARGET_SERVICE="/etc/systemd/system/${SERVICE_NAME}.service"

if [ -f "$SOURCE_SERVICE" ]; then
    cp "$SOURCE_SERVICE" "$TARGET_SERVICE"
    echo "Systemd unit file placed at ${TARGET_SERVICE}"
else
    echo "[ERROR] Source service file $SOURCE_SERVICE not found."
    exit 1
fi


# ==============================================================================
# PHASE 2: LAYOUT MANAGEMENT & INITDB (TDE-ENABLED)
# ==============================================================================
log "Preparing Enterprise Layout Directories"
mkdir -p "$BINARY_TOP" "$DATA_TOP" "${DATA_TOP}/conf.d"
chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$BINARY_TOP" "$DATA_TOP"

log "Relocating EPAS ${EPAS_VERSION} Binaries to $BINARY_TOP"
if [ -d "$SRC_BINARY_DIR" ]; then
    cp -a "$SRC_BINARY_DIR"/. "$BINARY_TOP/"
    chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$BINARY_TOP"
else
    echo "[ERROR] Source directory $SRC_BINARY_DIR missing."
    exit 1
fi

log "Initializing Clean Database Cluster Core with TDE"
if [ -z "$(ls -A "$DATA_TOP" | grep -v 'conf.d')" ]; then
    # Injecting TDE options during the native initialization phase
    su - "$SYSTEM_USER" -c "export PGDATAKEYWRAPCMD='${TDE_WRAP_CMD}'; \
                            export PGDATAKEYUNWRAPCMD='${TDE_UNWRAP_CMD}'; \
                            ${BINARY_TOP}/bin/initdb --data-encryption=128 -D ${DATA_TOP}"
else
    echo "Data directory is already initialized. Skipping initdb."
fi

# ==============================================================================
# PHASE 3: MODULAR STRUCTURING & SYSTEMD CUSTOMIZATION
# ==============================================================================
log "Linking Architecture to conf.d Structure"
PG_CONF="${DATA_TOP}/postgresql.conf"

# Append include_dir parameter to primary engine config file if not already present
if ! grep -q "include_dir = 'conf.d'" "$PG_CONF"; then
    cat << EOF >> "$PG_CONF"

#------------------------------------------------------------------------------
# MODULAR CONFIGURATION EXTRACTIONS
#------------------------------------------------------------------------------
include_dir = 'conf.d'
port = ${PRIMARY_PORT}
EOF
fi

log "Customizing systemd configuration at $TARGET_SERVICE"
sed -i "s|^Environment=PGDATA=.*|Environment=PGDATA=${DATA_TOP}|" "$TARGET_SERVICE"
sed -i "s|^ExecStart=.*|ExecStart=${BINARY_TOP}/bin/pg_ctl start -D \${PGDATA} -s -w -t \${PGSTARTTIMEOUT}|" "$TARGET_SERVICE"
sed -i "s|^ExecStop=.*|ExecStop=${BINARY_TOP}/bin/pg_ctl stop -D \${PGDATA} -s -m fast|" "$TARGET_SERVICE"
sed -i "s|^ExecReload=.*|ExecReload=${BINARY_TOP}/bin/pg_ctl reload -D \${PGDATA} -s|" "$TARGET_SERVICE"
sed -i "/^Environment=PGDATA=.*/a Environment=PGDATAKEYWRAPCMD='${TDE_WRAP_CMD}'" "$TARGET_SERVICE"
sed -i "/^Environment=PGDATA=.*/a Environment=PGDATAKEYUNWRAPCMD='${TDE_UNWRAP_CMD}'" "$TARGET_SERVICE"

systemctl daemon-reload

log "SUCCESS: EPAS ${EPAS_VERSION} Base Layout Init Complete"
echo "Next Step: Run your post-install setup scripts against this instance."