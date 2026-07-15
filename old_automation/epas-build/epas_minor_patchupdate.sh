#!/usr/bin/env bash
# ==============================================================================
# EPAS Minor Patch Update Orchestrator
# ==============================================================================

set -euo pipefail

# --- Signal Handling (must be FIRST) ---
cleanup() {
    echo -e "\n\nOperation interrupted. Exiting."
    exit 130
}
trap cleanup INT TERM HUP

# --- Styling ---
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

heading() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }

prompt_yes_no() {
    while true; do
        read -p "$1 [y/n]: " response
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo -e "${RED}Please answer 'y' or 'n'.${NC}" ;;
        esac
    done
}

prompt_default() {
    local prompt_msg="$1"
    local default_val="$2"
    local var_name="$3"
    local input

    read -p "$(echo -e "${YELLOW}${prompt_msg} [${default_val}]: ${NC}")" input
    # SAFE: no eval, no command injection
    printf -v "$var_name" '%s' "${input:-$default_val}"
}

# --- Lock File (prevent concurrent runs) ---
LOCKFILE="/tmp/epas_patch_$(id -u).lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    echo -e "${RED}Another patch operation is already running. Aborting.${NC}"
    exit 1
fi

# --- 1. Version Selection ---
echo -e "${BOLD}EPAS Minor Patch Orchestrator${NC}"
echo "---------------------------------"
options=("EPAS 14" "EPAS 15" "EPAS 16" "EPAS 17" "Exit")
for i in "${!options[@]}"; do
    echo "  $((i+1))) ${options[$i]}"
done

while true; do
    read -p "Select target version [1-${#options[@]}]: " choice
    if [[ "$choice" =~ ^[1-5]$ ]]; then break; fi
    echo -e "${RED}Invalid selection.${NC}"
done

[ "$choice" -eq 5 ] && { echo "Exiting."; exit 0; }
TARGET_VERSION=$((13 + choice))

# --- 2. Environment Configuration ---
heading "Environment Configuration"

# Detect defaults from environment first, fallback to hardcoded paths
default_pghome="${PGHOME:-/usr/edb/as${TARGET_VERSION}}"
default_pgdata="${PGDATA:-/u00/data/as${TARGET_VERSION}}"

prompt_default "PGHOME path" "$default_pghome" "PGHOME"
prompt_default "PGDATA path" "$default_pgdata" "PGDATA"
prompt_default "Database OS User" "enterprisedb" "REQ_USER"

# Validate paths are absolute
[[ "$PGHOME" = /* ]] || { echo -e "${RED}PGHOME must be an absolute path.${NC}"; exit 1; }
[[ "$PGDATA" = /* ]] || { echo -e "${RED}PGDATA must be an absolute path.${NC}"; exit 1; }

export PGHOME PGDATA
export PATH="$PGHOME/bin:$PATH"

# Setup Logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/upgrade_epas${TARGET_VERSION}_$(date +%Y%m%d_%H%M%S).log"

# Redirect stdout/stderr to log (safer than process substitution)
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo -e "\n${GREEN}Resolved Environment:${NC}"
echo "  PGHOME  : $PGHOME"
echo "  PGDATA  : $PGDATA"
echo "  OS User : $REQ_USER"
echo "  Log     : $LOG_FILE"

if [ ! -d "$PGHOME" ] || [ ! -d "$PGDATA" ]; then
    echo -e "${YELLOW}Warning: PGHOME or PGDATA directories do not exist.${NC}"
    prompt_yes_no "Continue anyway?" || exit 1
fi

# --- 3. Pre-Flight Checks ---
heading "Pre-Flight Checks"

current_user="${USER:-$(whoami)}"
echo "Current user: $current_user"

if [ "$current_user" != "$REQ_USER" ]; then
    echo -e "${YELLOW}Warning: Running as '$current_user', expected '$REQ_USER'.${NC}"
    prompt_yes_no "Proceed anyway?" || exit 1
fi

if ! command -v pg_ctl &>/dev/null; then
    echo -e "${RED}Error: pg_ctl not found in $PGHOME/bin.${NC}"
    exit 1
fi

# Disk space check (portable)
if command -v stat &>/dev/null; then
    avail_gb=$(df -B1G "$PGDATA" 2>/dev/null | awk 'NR==2 {print $4}' || echo "?")
    echo "Available space: ${avail_gb} GB"
fi

prompt_yes_no "Proceed with patching?" || exit 0

# --- Step 1: Stop Database ---
heading "Step 1/5: Database Shutdown"

pg_status=$(pg_ctl -D "$PGDATA" status 2>/dev/null && echo "running" || echo "stopped")

if [ "$pg_status" = "stopped" ]; then
    echo "Database is already stopped."
else
    echo -e "${RED}${BOLD}WARNING:${NC} Active sessions will be terminated."
    if prompt_yes_no "Execute fast shutdown?"; then
        pg_ctl -D "$PGDATA" stop -m fast -w -t 60
    else
        echo "Shutdown declined. Aborting."; exit 0
    fi
fi

# --- Step 2: OS Package Upgrade ---
heading "Step 2/5: OS Package Upgrade"
echo "Run manually: sudo dnf upgrade -y edb-as${TARGET_VERSION}-server edb-as${TARGET_VERSION}-server-libs"
echo ""
echo "  1) Packages already updated / Continue"
echo "  2) Attempt automatic upgrade (requires NOPASSWD sudo)"
echo "  3) Abort"
read -p "Choice [1-3]: " pkg_choice

case "$pkg_choice" in
    2)
        if ! sudo -n dnf upgrade -y "edb-as${TARGET_VERSION}-server" "edb-as${TARGET_VERSION}-server-libs"; then
            echo -e "${RED}Automatic upgrade failed.${NC}"
            prompt_yes_no "Completed manually?" || exit 1
        fi
        ;;
    3) echo "Aborting."; exit 0 ;;
    *)  prompt_yes_no "Confirm packages are updated?" || exit 1 ;;
esac

# --- Step 3: Restart Engine ---
heading "Step 3/5: Engine Restart"
if prompt_yes_no "Restart EPAS with updated binaries?"; then
    pg_ctl -D "$PGDATA" start -w -t 60 -l "$PGDATA/log/startup.log"
else
    echo "Restart declined. Database remains stopped."; exit 0
fi

# --- Step 4: SQL Patch Catalogs ---
heading "Step 4/5: Database Catalog Patching"
errors=0

if [ -x "$PGHOME/bin/edb_sqlpatch" ]; then
    if prompt_yes_no "Execute 'edb_sqlpatch -af'?"; then
        if ! "$PGHOME/bin/edb_sqlpatch" -af; then
            echo -e "${RED}Catalog patching failed.${NC}"
            ((errors++))
        fi
    fi
else
    echo -e "${YELLOW}edb_sqlpatch not found. Skipping.${NC}"
fi

# --- Step 5: Verification ---
heading "Step 5/5: Final Verification"

echo -n "Process status... "
if pg_ctl -D "$PGDATA" status &>/dev/null; then
    echo -e "${GREEN}Running${NC}"
else
    echo -e "${RED}Stopped${NC}"
    ((errors++))
fi

echo -n "Connectivity... "
if "$PGHOME/bin/psql" -tc "SELECT 1;" 2>/dev/null | grep -q "1"; then
    echo -e "${GREEN}OK${NC}"
    active_ver=$("$PGHOME/bin/psql" -tc "SELECT version();" 2>/dev/null | sed -n 's/.*Advanced Server \([0-9.]*\).*/\1/p')
    [ -n "$active_ver" ] && echo "Version: $active_ver"
else
    echo -e "${YELLOW}No connection (check auth/logs)${NC}"
fi

echo -e "\n---------------------------------"
if [ "$errors" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}Patch completed successfully!${NC}"
else
    echo -e "${YELLOW}${BOLD}Completed with $errors error(s). Check logs.${NC}"
fi

echo "Log: $LOG_FILE"