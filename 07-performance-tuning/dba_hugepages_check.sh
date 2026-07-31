#!/usr/bin/env bash
#
# dba_hugepages_check.sh - DBA validation after OS admin runs setup
# Run as enterprisedb (or any EPAS superuser).
#

set -euo pipefail

DB_NAME="edb"
EPAS_USER="enterprisedb"
SERVICE_NAME="edb-as-17"
PRIMARY_PORT="5444"
ENV_FILE=""

log()  { echo -e "[DBA-INFO] $*"; }
warn() { echo -e "[DBA-WARN] $*" >&2; }
err()  { echo -e "[DBA-ERROR] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--env /path/to/deploy.env]"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            ;;
    esac
done

# Load deploy.env if provided
if [[ -n "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" ]] || err "Environment file not found: $ENV_FILE"
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
    EPAS_USER="${SYSTEM_USER:-$EPAS_USER}"
    SERVICE_NAME="${SERVICE_NAME:-edb-as-17}"
    PRIMARY_PORT="${PRIMARY_PORT:-5444}"
fi

PSQL="psql -d $DB_NAME -p $PRIMARY_PORT -v ON_ERROR_STOP=1"

log "===================================================="
log " DBA Phase 1 Validation"
log "===================================================="
log "User: $EPAS_USER | Port: $PRIMARY_PORT | Service: $SERVICE_NAME"

# 1. Check OS HugePages
HP_TOTAL=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
HP_SIZE=$(awk '/^Hugepagesize/ {print $2}' /proc/meminfo)
SB_RAW=$($PSQL -Atc "SHOW shared_buffers;")
SB_KB=$(echo "$SB_RAW" | awk '
    /GB/ {gsub(/[^0-9]/,""); print $1*1024*1024; next}
    /MB/ {gsub(/[^0-9]/,""); print $1*1024; next}
    /kB/ {gsub(/[^0-9]/,""); print $1; next}
    {print $1/1024}
')

SB_PAGES=$(( (SB_KB + HP_SIZE - 1) / HP_SIZE + 20 ))

log "OS HugePages Total: $HP_TOTAL"
log "shared_buffers:     $SB_RAW (~$SB_PAGES pages required)"

[[ "$HP_TOTAL" -ge "$SB_PAGES" ]] || err "Insufficient OS HugePages ($HP_TOTAL < $SB_PAGES). Do not proceed."

# 2. Check EPAS huge_pages setting
HP_SETTING=$($PSQL -Atc "SHOW huge_pages;")
log "Current huge_pages: $HP_SETTING"

if [[ "$HP_SETTING" == "on" ]]; then
    log "PASS: huge_pages is already 'on'."
elif [[ "$HP_SETTING" == "try" ]]; then
    warn "huge_pages is 'try' — EPAS may silently fall back to normal pages."
    log "Fix: ALTER SYSTEM SET huge_pages = 'on';"
elif [[ "$HP_SETTING" == "off" ]]; then
    warn "huge_pages is 'off'."
    log "Fix: ALTER SYSTEM SET huge_pages = 'on';"
fi

# 3. Optional apply
if [[ "$HP_SETTING" != "on" ]]; then
    read -r -p "Enable huge_pages='on' now? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        $PSQL -c "ALTER SYSTEM SET huge_pages = 'on';"
        log "Configuration updated. Restart EPAS to activate:"
        log "  sudo systemctl restart $SERVICE_NAME"
    fi
fi

log "===================================================="
log " DBA Phase 1 Complete."
log "===================================================="