#!/usr/bin/env bash
set -euo pipefail

# Shared start-up: --env handling, config loading, settings summary (lib/common.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env | conf/site.env] [--yes]
Prepares the primary for replication: creates REP_USER with a random password (stored in
the EPAS user ~/.pgpass), adds replication rules for SUBNET_CIDR to pg_hba.conf, reloads EPAS.
Run as: the EPAS OS user (SYSTEM_USER), e.g. sudo su - enterprisedb. Config is required (default: conf/site.env in the repo).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required

# Ensure variables with no safe default are bound (avoids 'set -u' crash)
: "${SYSTEM_USER:?SYSTEM_USER variable is unset}"
: "${PRIMARY_PORT:?PRIMARY_PORT variable is unset}"
: "${REP_USER:?REP_USER variable is unset}"
: "${SUBNET_CIDR:?SUBNET_CIDR variable is unset}"
: "${DATA_TOP:?DATA_TOP variable is unset}"
: "${BINARY_TOP:?BINARY_TOP variable is unset}"

# ==========================================
# SAFEGUARDS & USER VALIDATION
# ==========================================
CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "$SYSTEM_USER" ]; then
    log_error "This script must be run directly as the system user: '${SYSTEM_USER}' (Current user: '${CURRENT_USER}')."
    log_error "Please switch user: 'sudo su - ${SYSTEM_USER}' and execute again."
    exit 1
fi

show_config SYSTEM_USER BINARY_TOP DATA_TOP PRIMARY_PORT REP_USER SUBNET_CIDR
confirm_or_exit "create replication user ${REP_USER} (if missing), add pg_hba.conf rules for ${SUBNET_CIDR} and reload EPAS on port ${PRIMARY_PORT}"

log_info "START: Preparing Primary Node (Running as database user: ${SYSTEM_USER})"

# ==========================================
# 1. CREATE REPLICATION USER & SECURE PASS
# ==========================================
# Check if replication user already exists using local socket authentication
USER_EXISTS=$("${BINARY_TOP}/bin/psql" -p "${PRIMARY_PORT}" -d postgres \
    -tAc "SELECT 1 FROM pg_roles WHERE rolname='${REP_USER}';" 2>/dev/null || echo "0")

if [ "$USER_EXISTS" != "1" ]; then
    # Generate a strong 24-character random password
    REP_PASSWORD=$(openssl rand -base64 18)
    log_info "Creating replication user '${REP_USER}' with secure password..."
    
    "${BINARY_TOP}/bin/psql" -p "${PRIMARY_PORT}" -d postgres \
        -c "CREATE ROLE ${REP_USER} WITH REPLICATION LOGIN PASSWORD '${REP_PASSWORD}';" > /dev/null
    
    # Locate active user's home directory
    PGPASS_FILE="${HOME}/.pgpass"
    log_info "Staging replication credentials in ${PGPASS_FILE}..."
    
    # Securely append credentials directly into user's .pgpass
    # Format: hostname:port:database:username:password
    echo "*:${PRIMARY_PORT}:*:${REP_USER}:${REP_PASSWORD}" >> "$PGPASS_FILE"
    chmod 0600 "$PGPASS_FILE"
    log_warn "ACTION: the standby needs this password too. Copy the '${REP_USER}' line from ${PGPASS_FILE}"
    log_warn "        into ~/.pgpass of ${SYSTEM_USER} on ${STANDBY_HOST:-the standby} (chmod 600) before running epas-rebuild-standby.sh."
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

RULE_REPLICATION="host    replication     ${REP_USER}     ${SUBNET_CIDR}          scram-sha-256"
RULE_DB_ACCESS="host    postgres        ${REP_USER}     ${SUBNET_CIDR}          scram-sha-256"

# Check and inject rules securely
if ! grep -Fxq "$RULE_REPLICATION" "$HBA_CONF"; then
    log_info "Injecting replication network access rules into pg_hba.conf..."
    
    # Since we are already running as the owner, we can directly rewrite the file without sudo
    TEMP_HBA=$(mktemp)
    echo -e "# Replication network rules added dynamically\n${RULE_REPLICATION}\n${RULE_DB_ACCESS}" > "$TEMP_HBA"
    cat "$HBA_CONF" >> "$TEMP_HBA"
    mv "$TEMP_HBA" "$HBA_CONF"
    
    # Ensure standard database permission flags remain intact
    chmod 0600 "$HBA_CONF"
else
    log_info "pg_hba.conf replication rule already exists."
fi

# ==========================================
# 3. RELOAD CONFIGURATION
# ==========================================
log_info "Reloading EPAS configuration dynamically..."
"${BINARY_TOP}/bin/pg_ctl" -D "$DATA_TOP" reload

log_audit "Primary prepared for replication: user ${REP_USER}, pg_hba rules for ${SUBNET_CIDR}, port ${PRIMARY_PORT}"
log_info "SUCCESS: Primary node is prepared. Ready to initiate replication stream."