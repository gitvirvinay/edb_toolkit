#!/usr/bin/env bash
#
# dba_resize_buffers.sh - Plan and apply shared_buffers changes safely.
# Run as enterprisedb. Requires OS admin to run setup_epas_kernel.sh first.
#

set -euo pipefail

EPAS_USER="enterprisedb"
DB_NAME="edb"
SERVICE_NAME="edb-as-17"
ENV_FILE=""
TARGET_MB=""

usage() {
    cat <<EOF
Usage: $0 -m <MB> [--env deploy.env] [--apply]

  -m <MB>     Target shared_buffers in megabytes (e.g., 8192)
  --env       Path to deploy.env
  --apply     Actually execute ALTER SYSTEM (default is dry-run)
  -h          This help

Examples:
  $0 -m 8192                  # Dry-run plan
  $0 -m 8192 --apply          # Apply change (restart still required)
EOF
    exit 1
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) TARGET_MB="$2"; shift 2 ;;
        --env) ENV_FILE="$2"; shift 2 ;;
        --apply) APPLY=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[[ -n "$TARGET_MB" ]] || usage

# --- Load deploy.env ---
if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
    EPAS_USER="${SYSTEM_USER:-$EPAS_USER}"
    SERVICE_NAME="${SERVICE_NAME:-edb-as-17}"
    DB_NAME="${DB_NAME:-edb}"
fi

PSQL="psql -U $EPAS_USER -d $DB_NAME -v ON_ERROR_STOP=1"

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
    echo "Action: Ask OS admin to re-run setup_epas_kernel.sh after stopping EPAS,"
    echo "        or manually increase vm.nr_hugepages in sysctl."
    exit 1
fi

# --- Dry-run or apply ---
if [[ "${APPLY:-false}" != "true" ]]; then
    echo "[DRY-RUN] Ready to apply. Re-run with --apply to execute:"
    echo ""
    echo "  ALTER SYSTEM SET shared_buffers = '${TARGET_MB}MB';"
    echo ""
    echo "Then restart EPAS:"
    echo "  sudo systemctl restart $SERVICE_NAME"
    exit 0
fi

# --- Apply ---
echo "[APPLY] ALTER SYSTEM SET shared_buffers = '${TARGET_MB}MB';"
$PSQL -c "ALTER SYSTEM SET shared_buffers = '${TARGET_MB}MB';"

echo ""
echo "============================================================"
echo " Configuration updated."
echo "============================================================"
echo "RESTART REQUIRED: sudo systemctl restart $SERVICE_NAME"
echo "After restart, verify with: SHOW shared_buffers;"