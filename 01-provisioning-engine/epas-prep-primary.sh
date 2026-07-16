#!/usr/bin/env bash
set -euo pipefail

# Source central logger
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

if [ "${1:-}" == "--env" ]; then shift; fi
if [ -z "${1:-}" ] || [ ! -f "$1" ]; then
    echo "Usage: $0 [--env path_to_deploy.env]"
    exit 1
fi
source "$1"

# Ensure variables with no safe default are bound
: "${SYSTEM_USER:?SYSTEM_USER variable is unset}"
: "${SYSTEM_GROUP:?SYSTEM_GROUP variable is unset}"
: "${PRIMARY_PORT:?PRIMARY_PORT variable is unset}"
: "${REP_USER:?REP_USER variable is unset}"
: "${SUBNET_CIDR:?SUBNET_CIDR variable is unset}"
: "${DATA_TOP:?DATA_TOP variable is unset}"
: "${BINARY_TOP:?BINARY_TOP variable is unset}"

log_info "START: Preparing Primary Node for Standby Replication Setup"

# ==========================================
# 1. CREATE REPLICATION USER & SECURE PASS
# ==========================================
# Check if the replication user already exists
USER_EXISTS=$(sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/psql" -p "${PRIMARY_PORT}" -d postgres \
    -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REP_USER}';" 2>/dev/null || echo "0")

if [ "$USER_EXISTS" != "1" ]; then
    # Generate a strong 24-character random password
    REP_PASSWORD=$(openssl rand -base64 18)
    log_info "Creating replication user '${REP_USER}' with secure password..."
    
    sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/psql" -p "${PRIMARY_PORT}" -d postgres \
        -c "CREATE ROLE ${REP_USER} WITH REPLICATION LOGIN PASSWORD '${REP_PASSWORD}';" > /dev/null
    
    # Store replication credentials securely in the SYSTEM_USER's .pgpass file
    # This allows pg_basebackup and psql connections to authenticate seamlessly.
    USER_HOME=$(eval echo "~${SYSTEM_USER}")
    PGPASS_FILE="${USER_HOME}/.pgpass"
    
    log_info "Staging replication credentials in ${PGPASS_FILE}..."
    sudo -u "$SYSTEM_USER" touch "$PGPASS_FILE"
    sudo -u "$SYSTEM_USER" chmod 0600 "$PGPASS_FILE"
    
    # Format: hostname:port:database:username:password
    # Staging both local connections and IP-bound connections
    echo "*:${PRIMARY_PORT}:*:${REP_USER}:${REP_PASSWORD}" | sudo -u "$SYSTEM_USER" tee -a "$PGPASS_FILE" > /dev/null
else
    log_warn "Replication user '${REP_USER}' already exists. Skipping role creation."
fi

# ==========================================
# 2. MODIFY PG_HBA.CONF
# ==========================================
HBA_CONF="${DATA_TOP}/pg_hba.conf"

if [ ! -f "$HBA_CONF" ]; then
    log_error "Target pg_hba.conf file not found at ${HBA_CONF}."
    exit 1
fi

log_info "Validating pg_hba.conf configuration rules..."

# Prepare the replication network rule entries
RULE_REPLICATION="host    replication     ${REP_USER}     ${SUBNET_CIDR}          scram-sha-256"
RULE_DB_ACCESS="host    postgres        ${REP_USER}     ${SUBNET_CIDR}          scram-sha-256"

# Check and inject the replication connection rule
if ! grep -Fxq "$RULE_REPLICATION" "$HBA_CONF"; then
    log_info "Injecting replication network access rule into pg_hba.conf..."
    # Insert before local connections/catch-alls by prepending to the top of the file
    TEMP_HBA=$(mktemp)
    echo -e "# Replication network rule added dynamically\n${RULE_REPLICATION}\n${RULE_DB_ACCESS}" > "$TEMP_HBA"
    cat "$HBA_CONF" >> "$TEMP_HBA"
    sudo -u "$SYSTEM_USER" cp "$TEMP_HBA" "$HBA_CONF"
    rm -f "$TEMP_HBA"
else
    log_info "pg_hba.conf replication rule already exists."
fi

# ==========================================
# 3. RELOAD CONFIGURATION
# ==========================================
log_info "Reloading EPAS configuration to apply modifications..."
sudo -u "$SYSTEM_USER" "${BINARY_TOP}/bin/pg_ctl" -D "$DATA_TOP" reload

log_info "SUCCESS: Primary node is prepared. Ready to initiate replication stream."