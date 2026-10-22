#!/usr/bin/env bash
#
# dba-resize-buffers.sh - Plan and apply shared_buffers changes safely.
# Run as enterprisedb. Requires OS admin to run setup-epas-kernel.sh first.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

TARGET_MB=""
APPLY=false

usage() {
    cat <<USAGE
Usage: $0 -m <MB> [--env conf/site.env] [--apply] [--yes]

  -m <MB>     Target shared_buffers in megabytes (e.g., 8192)
  --env       Config file (default: conf/site.env in the repo)
  --apply     Actually execute ALTER SYSTEM (default is a dry-run plan); requires a config file
  --yes       Do not ask for confirmation before --apply
  -h          This help

Examples:
  $0 -m 8192                  # Dry-run plan
  $0 -m 8192 --apply          # Apply change (restart still required)
USAGE
    exit "${1:-0}"
}

# --- Parse args ---
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m)        TARGET_MB="${2:-}"; shift 2 || usage 1 ;;
        --apply)   APPLY=true; shift ;;
        -h|--help) usage 0 ;;
        *)         log_error "Unknown option: $1"; usage 1 ;;
    esac
done

[[ -n "$TARGET_MB" ]] || usage 1
[[ "$TARGET_MB" =~ ^[0-9]+$ && "$TARGET_MB" -gt 0 ]] || die "-m must be a positive number of MB: ${TARGET_MB}"

# --- Load config (required for --apply; dry-run may use defaults) ---
if [[ "$APPLY" == true ]]; then load_env required; else load_env optional; fi
EPAS_USER="$SYSTEM_USER"
DB_NAME="${DB_NAME:-edb}"
show_config SERVICE_NAME EPAS_USER PRIMARY_PORT DB_NAME TARGET_MB APPLY

PSQL="psql -U $EPAS_USER -d $DB_NAME -p $PRIMARY_PORT -v ON_ERROR_STOP=1"

# --- Gather facts ---
HP_SIZE=$(awk '/^Hugepagesize/ {print $2}' /proc/meminfo)
HP_TOTAL=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
CURRENT_SB=$($PSQL -Atc "SHOW shared_buffers;")
PAGES_NEEDED=$(( (TARGET_MB * 1024 / HP_SIZE) + (TARGET_MB * 1024 / HP_SIZE / 10) + 20 ))

echo "============================================================"
echo " shared_buffers Resize Plan"
echo "============================================================"
echo "Current shared_buffers: $CURRENT_SB"
echo "Target shared_buffers:  ${TARGET_MB}MB"
echo "OS HugePages Total:     $HP_TOTAL"
echo "OS HugePage Size:       ${HP_SIZE}kB"
echo "Pages Required:         $PAGES_NEEDED (with 10% headroom + 20)"
echo ""

# --- Safety gate ---
if [[ "$HP_TOTAL" -lt "$PAGES_NEEDED" ]]; then
    echo "[FAIL] Insufficient OS HugePages ($HP_TOTAL < $PAGES_NEEDED)."
    echo "Action: Ask OS admin to re-run setup-epas-kernel.sh after stopping EPAS,"
    echo "        or manually increase vm.nr_hugepages in sysctl."
    exit 1
fi

# --- Dry-run or apply ---
if [[ "$APPLY" != "true" ]]; then
    echo "[DRY-RUN] Ready to apply. Re-run with --apply to execute:"
    echo ""
    echo "  ALTER SYSTEM SET shared_buffers = '${TARGET_MB}MB';"
    echo ""
    echo "Then restart EPAS:"
    echo "  sudo systemctl restart $SERVICE_NAME"
    exit 0
fi

# --- Apply ---
confirm_or_exit "ALTER SYSTEM SET shared_buffers = '${TARGET_MB}MB' on ${SERVICE_NAME} (was ${CURRENT_SB}; restart required afterwards)"
echo "[APPLY] ALTER SYSTEM SET shared_buffers = '${TARGET_MB}MB';"
$PSQL -c "ALTER SYSTEM SET shared_buffers = '${TARGET_MB}MB';"
log_audit "shared_buffers set to ${TARGET_MB}MB on ${SERVICE_NAME} (was ${CURRENT_SB}) — restart pending"

echo ""
echo "============================================================"
echo " Configuration updated."
echo "============================================================"
echo "RESTART REQUIRED: sudo systemctl restart $SERVICE_NAME"
echo "After restart, verify with: SHOW shared_buffers;"