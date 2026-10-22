#!/usr/bin/env bash
#
# setup-epas-kernel.sh - OS Kernel Tuning for EPAS (HugePages + Overcommit + Writeback)
# Must be executed as root.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

# Route this script's messages through the central logger (console + file + syslog)
log()  { log_info "$*"; }
warn() { log_warn "$*"; }
err()  { die "$*"; }

USER_OVERRIDE=""
usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--user <os_user>] [--yes]
OS kernel tuning for EPAS: HugePages, strict overcommit, dirty writeback, memlock limit, THP disable.
Writes /etc/sysctl.d/99-<service>-kernel.conf and /etc/security/limits.d/99-<service>-memlock.conf.
Shows the calculated values and asks before writing anything. Must run as root.
Settings: EPAS_VERSION/SERVICE_NAME, SYSTEM_USER — from conf/site.env (required); --user overrides SYSTEM_USER.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)    [[ -n "${2:-}" ]] || die "--user needs a value"; USER_OVERRIDE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)         die "Unknown option: $1 (see --help)" ;;
    esac
done

load_env required
require_root
EPAS_USER="${USER_OVERRIDE:-$SYSTEM_USER}"
show_config EPAS_VERSION SERVICE_NAME EPAS_USER

log "===================================================="
log " Starting EPAS OS Kernel Optimization"
log "===================================================="
log "Target User: $EPAS_USER | Service: $SERVICE_NAME"

# ------------------------------------------------------------------
# 1. System Info
# ------------------------------------------------------------------
TOTAL_KB=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
HP_SIZE_KB=$(awk '/^Hugepagesize/ {print $2}' /proc/meminfo)
[[ -n "$HP_SIZE_KB" && "$HP_SIZE_KB" -gt 0 ]] || err "Cannot read Hugepagesize from /proc/meminfo."

EPAS_GID=$(id -g "$EPAS_USER" 2>/dev/null) || err "OS user '$EPAS_USER' does not exist."

# ------------------------------------------------------------------
# 2. Calculate HugePages from running EPAS shared memory
# ------------------------------------------------------------------
log "[1/6] Calculating HugePages required by EPAS..."
# EPAS 15/17 keeps shared_buffers in mmap memory, which 'ipcs -m' cannot see (it only shows a
# ~56-byte SysV segment), so the size is asked from EPAS itself. Order of preference:
#   1. running EPAS 15+ : SHOW shared_memory_size_in_huge_pages   (exact, includes all shared memory)
#   2. stopped EPAS 15+ : edb-postgres -D $DATA_TOP -C shared_memory_size_in_huge_pages
#   3. running EPAS <15 : shared_buffers (same method as dba-resize-buffers.sh / dba-epas-verify.sh)
#   4. last resort      : 25% of RAM, with a warning
BIN_DIR="${SRC_BINARY_DIR:-/usr/edb/as${EPAS_VERSION}}/bin"
PSQL_BIN="${BIN_DIR}/psql";        [[ -x "$PSQL_BIN" ]] || PSQL_BIN="psql"
PG_BIN="${BIN_DIR}/edb-postgres";  [[ -x "$PG_BIN" ]]   || PG_BIN="${BIN_DIR}/postgres"
DB_NAME="${DB_NAME:-edb}"
epas_sql() { sudo -u "$EPAS_USER" "$PSQL_BIN" -X -At -p "$PRIMARY_PORT" -d "$DB_NAME" -c "$1" 2>/dev/null; }

RAW_PAGES=""
SIZING_SOURCE=""
v=$(epas_sql "SHOW shared_memory_size_in_huge_pages;" || true)
if [[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]]; then
    RAW_PAGES="$v"; SIZING_SOURCE="running EPAS (shared_memory_size_in_huge_pages)"
fi
if [[ -z "$RAW_PAGES" && -n "${DATA_TOP:-}" && -x "$PG_BIN" ]]; then
    v=$(sudo -u "$EPAS_USER" "$PG_BIN" -D "$DATA_TOP" -C shared_memory_size_in_huge_pages 2>/dev/null || true)
    if [[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]]; then
        RAW_PAGES="$v"; SIZING_SOURCE="stopped EPAS (${PG_BIN##*/} -C shared_memory_size_in_huge_pages)"
    fi
fi
if [[ -z "$RAW_PAGES" ]]; then
    v=$(epas_sql "SELECT pg_size_bytes(current_setting('shared_buffers')) / 1024;" || true)
    if [[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]]; then
        RAW_PAGES=$(( (v + HP_SIZE_KB - 1) / HP_SIZE_KB )); SIZING_SOURCE="running EPAS (shared_buffers = ${v} KB)"
    fi
fi
if [[ -z "$RAW_PAGES" ]]; then
    warn "Could not get the shared memory size from EPAS (not reachable on port ${PRIMARY_PORT}, and no usable DATA_TOP)."
    warn "Falling back to an ESTIMATE of 25% of RAM — check vm.nr_hugepages before setting huge_pages='on'."
    RAW_PAGES=$(( (TOTAL_KB / 4 + HP_SIZE_KB - 1) / HP_SIZE_KB )); SIZING_SOURCE="ESTIMATE (25% of RAM)"
fi

SHARED_KB=$(( RAW_PAGES * HP_SIZE_KB ))
TARGET_PAGES=$(( RAW_PAGES + (RAW_PAGES / 10) + 20 ))

log "      Sizing source: ${SIZING_SOURCE}"
log "      Total RAM:     ${TOTAL_KB} KB"
log "      Shared Memory: ${SHARED_KB} KB (${RAW_PAGES} pages)"
log "      Page Size:     ${HP_SIZE_KB} KB"
log "      Target Pages:  $TARGET_PAGES"

# ------------------------------------------------------------------
# 3. Calculate Overcommit Limit (kbytes)
# ------------------------------------------------------------------
log "[2/6] Calculating strict overcommit limit..."

HP_RESERVED_KB=$(( TARGET_PAGES * HP_SIZE_KB ))
AVAILABLE_KB=$(( TOTAL_KB - HP_RESERVED_KB ))
# 80% of non-HugePage RAM + fixed 2 GB buffer for sidecars
OVERCOMMIT_KB=$(( (AVAILABLE_KB * 80 / 100) + 2097152 ))

# Safety floor: never go below 1 GB
if [[ "$OVERCOMMIT_KB" -lt 1048576 ]]; then
    OVERCOMMIT_KB=1048576
    warn "Overcommit limit fell below 1 GB; clamped to 1 GB."
fi

log "      HugePages Reserved: ${HP_RESERVED_KB} KB"
log "      Available RAM:      ${AVAILABLE_KB} KB"
log "      Overcommit Limit:   ${OVERCOMMIT_KB} KB"

# ------------------------------------------------------------------
# 4. Write sysctl drop-in
# ------------------------------------------------------------------
SYSCTL_CONF="/etc/sysctl.d/99-${SERVICE_NAME}-kernel.conf"
LIMITS_CONF="/etc/security/limits.d/99-${SERVICE_NAME}-memlock.conf"
confirm_or_exit "write ${SYSCTL_CONF} (vm.nr_hugepages=${TARGET_PAGES} from ${SIZING_SOURCE}, overcommit_kbytes=${OVERCOMMIT_KB}) and ${LIMITS_CONF}, apply with sysctl, and disable THP"
log "[3/6] Writing $SYSCTL_CONF..."

cat << EOF > "$SYSCTL_CONF"
# Auto-generated by setup-epas-kernel.sh
# --- HugePages ---
vm.nr_hugepages = $TARGET_PAGES
vm.hugetlb_shm_group = $EPAS_GID

# --- Strict Overcommit ---
# Prevents OOM killer from targeting the postmaster.
# Limit = 80% of (RAM - HugePages) + 2 GB fixed buffer.
vm.overcommit_memory = 2
vm.overcommit_kbytes = $OVERCOMMIT_KB

# --- Dirty Page Writeback (low-latency tuning) ---
# Flush smaller batches more often to avoid latency spikes.
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_writeback_centisecs = 200
EOF

sysctl -p "$SYSCTL_CONF" >/dev/null

# ------------------------------------------------------------------
# 5. Shell Limits (memlock for HugePages)
# ------------------------------------------------------------------
log "[4/6] Writing $LIMITS_CONF..."

MEMLOCK_KB=$(( TOTAL_KB * 75 / 100 ))

cat << EOF > "$LIMITS_CONF"
# Auto-generated by setup-epas-kernel.sh
# Cap memlock at 75 % of total RAM (${MEMLOCK_KB} kB) per Unix/Audit policy.
$EPAS_USER soft memlock ${MEMLOCK_KB}
$EPAS_USER hard memlock ${MEMLOCK_KB}
EOF

# ------------------------------------------------------------------
# 6. Disable Transparent Huge Pages
# ------------------------------------------------------------------
log "[5/6] Disabling Transparent Huge Pages..."

if command -v tuned-adm &>/dev/null; then
    mkdir -p /etc/tuned/epas-no-thp
    cat << EOF > /etc/tuned/epas-no-thp/tuned.conf
[main]
include=throughput-performance
[vm]
transparent_hugepages=never
EOF
    tuned-adm profile epas-no-thp >/dev/null 2>&1 || warn "tuned-adm profile switch failed; using sysfs fallback."
fi

if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
fi
if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
fi

# ------------------------------------------------------------------
# 7. Verification Gate
# ------------------------------------------------------------------
log "[6/6] Verifying kernel allocation..."
sleep 1

ACTUAL_PAGES=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
ACTUAL_OVERCOMMIT=$(awk '/^CommitLimit/ {print $2}' /proc/meminfo)

if [[ "$ACTUAL_PAGES" -lt "$TARGET_PAGES" ]]; then
    warn "Allocated only $ACTUAL_PAGES / $TARGET_PAGES HugePages."
    warn "Memory is likely fragmented. REBOOT before enabling huge_pages='on' in EPAS."
    HP_STATUS=1
else
    log "SUCCESS: $ACTUAL_PAGES HugePages allocated."
    HP_STATUS=0
fi

log "      CommitLimit: ${ACTUAL_OVERCOMMIT} KB"

# ------------------------------------------------------------------
# 8. Summary
# ------------------------------------------------------------------
log "===================================================="
log " OS Kernel Tuning Complete"
log "===================================================="
log ""
log "Parameters applied:"
log "  vm.nr_hugepages          = $TARGET_PAGES"
log "  vm.hugetlb_shm_group     = $EPAS_GID"
log "  vm.overcommit_memory     = 2"
log "  vm.overcommit_kbytes     = $OVERCOMMIT_KB"
log "  vm.dirty_background_ratio = 5"
log "  vm.dirty_ratio           = 10"
log "  vm.dirty_writeback_centisecs = 200"
log ""
log "Config files:"
log "  $SYSCTL_CONF"
log "  $LIMITS_CONF"
log ""

log_audit "Kernel tuning applied for ${SERVICE_NAME}: sizing=${SIZING_SOURCE}, nr_hugepages=${TARGET_PAGES} (allocated ${ACTUAL_PAGES}), overcommit_kbytes=${OVERCOMMIT_KB}, memlock_kb=${MEMLOCK_KB}"

if [[ "$HP_STATUS" -ne 0 ]]; then
    log "ACTION REQUIRED: Reboot to defragment memory for HugePages."
    exit 2
fi

log "Handoff to DBA: set huge_pages = 'on' in postgresql.conf and restart EPAS."
