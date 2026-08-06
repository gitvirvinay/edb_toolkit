#!/usr/bin/env bash
#
# dba_epas_verify.sh - DBA validation after setup_epas_kernel.sh
# Run as enterprisedb (or any EPAS superuser).
#

set -euo pipefail

DB_NAME="edb"
EPAS_USER="enterprisedb"
SERVICE_NAME="edb-as-17"
PRIMARY_PORT="5444"
ENV_FILE=""
APPLY=false

PASS=0
WARN=0
FAIL=0

log()    { echo -e "[DBA-INFO]  $*"; }
warn()   { echo -e "[DBA-WARN]  $*" >&2; ((WARN++)) || true; }
err()    { echo -e "[DBA-FAIL]  $*" >&2; ((FAIL++)) || true; }
pass()   { echo -e "[DBA-PASS]  $*"; ((PASS++)) || true; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--env /path/to/deploy.env] [--apply]"
            echo "  --apply   Auto-enable huge_pages='on' if not already set."
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
log " DBA Validation: EPAS Kernel Tuning"
log "===================================================="
log "User: $EPAS_USER | Port: $PRIMARY_PORT | Service: $SERVICE_NAME"

# ------------------------------------------------------------------
# 0. Pre-flight checks
# ------------------------------------------------------------------
if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    err "EPAS service '$SERVICE_NAME' is not running. Start it first."
fi

if ! $PSQL -Atc "SELECT 1;" >/dev/null 2>&1; then
    err "Cannot connect to EPAS on port $PRIMARY_PORT as user '$EPAS_USER'."
fi

# ------------------------------------------------------------------
# 1. OS HugePages vs shared_buffers
# ------------------------------------------------------------------
HP_TOTAL=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
HP_SIZE=$(awk '/^Hugepagesize/ {print $2}' /proc/meminfo)
HP_FREE=$(awk '/^HugePages_Free/ {print $2}' /proc/meminfo)
HP_RSVD=$(awk '/^HugePages_Rsvd/ {print $2}' /proc/meminfo)

SB_RAW=$($PSQL -Atc "SHOW shared_buffers;")

# Parse shared_buffers: PostgreSQL returns either '<number><unit>' or raw blocks (8kB each)
SB_KB=$(echo "$SB_RAW" | awk '
    /GB/ {gsub(/[^0-9.]/,""); printf "%d", $1*1024*1024; next}
    /MB/ {gsub(/[^0-9.]/,""); printf "%d", $1*1024; next}
    /kB/ {gsub(/[^0-9.]/,""); printf "%d", $1; next}
    /^[0-9]+$/ {printf "%d", $1*8; next}   # raw blocks -> 8kB blocks
    {printf "%d", $1/1024}
')

# Pages required = ceiling(SB_KB / HP_SIZE) + headroom (same as OS script)
SB_PAGES=$(( (SB_KB + HP_SIZE - 1) / HP_SIZE ))
SB_PAGES_WITH_HEADROOM=$(( SB_PAGES + (SB_PAGES / 10) + 20 ))

log "OS HugePages Total: $HP_TOTAL | Free: $HP_FREE | Rsvd: $HP_RSVD | Size: ${HP_SIZE}kB"
log "shared_buffers:     $SB_RAW (~$SB_PAGES pages, $SB_PAGES_WITH_HEADROOM with headroom)"

if [[ "$HP_TOTAL" -ge "$SB_PAGES_WITH_HEADROOM" ]]; then
    pass "OS HugePages sufficient ($HP_TOTAL >= $SB_PAGES_WITH_HEADROOM)."
else
    err "Insufficient OS HugePages ($HP_TOTAL < $SB_PAGES_WITH_HEADROOM). Do not proceed."
fi

# ------------------------------------------------------------------
# 2. EPAS huge_pages GUC
# ------------------------------------------------------------------
HP_SETTING=$($PSQL -Atc "SHOW huge_pages;")

if [[ "$HP_SETTING" == "on" ]]; then
    pass "huge_pages GUC is 'on'."
elif [[ "$HP_SETTING" == "try" ]]; then
    warn "huge_pages is 'try' — EPAS may silently fall back to normal pages."
    if [[ "$APPLY" == true ]]; then
        $PSQL -c "ALTER SYSTEM SET huge_pages = 'on';"
        log "Applied: ALTER SYSTEM SET huge_pages = 'on';"
        log "ACTION REQUIRED: Restart EPAS to activate."
    fi
elif [[ "$HP_SETTING" == "off" ]]; then
    err "huge_pages is 'off'."
    if [[ "$APPLY" == true ]]; then
        $PSQL -c "ALTER SYSTEM SET huge_pages = 'on';"
        log "Applied: ALTER SYSTEM SET huge_pages = 'on';"
        log "ACTION REQUIRED: Restart EPAS to activate."
    fi
fi

# ------------------------------------------------------------------
# 3. Runtime verification: is EPAS actually using HugePages?
# ------------------------------------------------------------------
POSTMASTER_PID=$(pgrep -u "$EPAS_USER" -f "postgres.*-D" | head -n1)

if [[ -z "$POSTMASTER_PID" ]]; then
    err "Cannot find postmaster PID for user '$EPAS_USER'."
else
    # Check smaps for Anonymous HugePages in the postmaster's address space
    HP_IN_USE=$(awk '/AnonymousHugePages/ {sum+=$2} END {print sum+0}' /proc/$POSTMASTER_PID/smaps 2>/dev/null || echo 0)
    if [[ "$HP_IN_USE" -gt 0 ]]; then
        pass "Postmaster PID $POSTMASTER_PID is using ${HP_IN_USE} kB of Anonymous HugePages."
    else
        warn "Postmaster PID $POSTMASTER_PID shows 0 kB Anonymous HugePages."
        warn "If EPAS was restarted after setting huge_pages='on', this indicates a failure."
    fi
fi

# ------------------------------------------------------------------
# 4. Transparent HugePages check
# ------------------------------------------------------------------
if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    THP_STATUS=$(cat /sys/kernel/mm/transparent_hugepage/enabled)
    if [[ "$THP_STATUS" == *"[never]"* ]]; then
        pass "Transparent HugePages are disabled."
    else
        err "Transparent HugePages are NOT disabled: $THP_STATUS"
    fi
else
    warn "Cannot determine THP status (sysfs not available)."
fi

# ------------------------------------------------------------------
# 5. Overcommit verification
# ------------------------------------------------------------------
OVERCOMMIT_MEM=$(sysctl -n vm.overcommit_memory)
OVERCOMMIT_KB=$(sysctl -n vm.overcommit_kbytes)

if [[ "$OVERCOMMIT_MEM" -eq 2 ]]; then
    pass "Strict overcommit enabled (vm.overcommit_memory = 2)."
    log "      CommitLimit: $(awk '/^CommitLimit/ {print $2}' /proc/meminfo) kB"
    log "      vm.overcommit_kbytes = $OVERCOMMIT_KB"
else
    err "Strict overcommit NOT enabled (vm.overcommit_memory = $OVERCOMMIT_MEM)."
fi

# ------------------------------------------------------------------
# 6. Dirty page writeback verification
# ------------------------------------------------------------------
DIRTY_BG=$(sysctl -n vm.dirty_background_ratio)
DIRTY_RATIO=$(sysctl -n vm.dirty_ratio)
DIRTY_WB=$(sysctl -n vm.dirty_writeback_centisecs)

if [[ "$DIRTY_BG" -eq 5 && "$DIRTY_RATIO" -eq 10 ]]; then
    pass "Dirty page ratios tuned (bg=$DIRTY_BG, ratio=$DIRTY_RATIO, centisecs=$DIRTY_WB)."
else
    warn "Dirty page ratios unexpected: bg=$DIRTY_BG, ratio=$DIRTY_RATIO, centisecs=$DIRTY_WB."
fi

# ------------------------------------------------------------------
# 7. Summary
# ------------------------------------------------------------------
log "===================================================="
log " Validation Summary"
log "===================================================="
log "PASS: $PASS | WARN: $WARN | FAIL: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    log "RESULT: FAILED — fix errors before enabling huge_pages in production."
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    log "RESULT: WARNING — review warnings; may require EPAS restart."
    exit 2
else
    log "RESULT: ALL CHECKS PASSED."
    exit 0
fi