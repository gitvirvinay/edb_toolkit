#!/usr/bin/env bash
#
# dba_memory_tuning.sh
# DBA script for EPAS memory audit, validation, and capacity planning.
# Run as enterprisedb (or any superuser with psql access).
# NO root privileges required. NO OS kernel modifications.
#
# Usage:
#   ./dba_memory_tuning.sh phase1-check            # Verify EPAS side is ready
#   ./dba_memory_tuning.sh phase2-audit            # Run multi-day audit SQL
#   ./dba_memory_tuning.sh phase3-plan -m <MB>     # Plan shared_buffers increase
#   ./dba_memory_tuning.sh phase3-apply -m <MB>    # Apply shared_buffers (restart needed)
#

set -euo pipefail

EPAS_USER="${EPAS_USER:-enterprisedb}"
DB_NAME="${DB_NAME:-edb}"
PSQL="psql -U $EPAS_USER -d $DB_NAME -v ON_ERROR_STOP=1"

log_info()  { echo "[DBA-INFO]  $*"; }
log_warn()  { echo "[DBA-WARN]  $*"; }
log_error() { echo "[DBA-ERROR] $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
    phase1-check            Verify huge_pages setting and OS readiness.
    phase2-audit            Run cache hit, spill, and DRITA audit SQL.
    phase3-plan -m <MB>     Plan shared_buffers increase to <MB>.
    phase3-apply -m <MB>    Apply shared_buffers increase (requires restart).

Options:
    -U <user>               Database user (default: enterprisedb)
    -d <database>           Database name (default: edb)

Environment:
    EPAS_USER               Same as -U
    DB_NAME                 Same as -d

Examples:
    $0 phase1-check
    $0 phase2-audit
    $0 phase3-plan -m 8192
    $0 phase3-apply -m 8192
EOF
    exit 1
}

# --- Helpers ---

get_os_hugepage_info() {
    local hp_total hp_size_kb hp_total_mb
    hp_total=$(awk '/^HugePages_Total/ {print $2}' /proc/meminfo)
    hp_size_kb=$(awk '/^Hugepagesize/ {print $2}' /proc/meminfo)
    hp_total_mb=$(( hp_total * hp_size_kb / 1024 ))
    echo "$hp_total $hp_size_kb $hp_total_mb"
}

parse_shared_buffers_kb() {
    local raw="$1"
    # Handles '8GB', '8192MB', '8388608kB', or raw bytes
    echo "$raw" | awk '
        /[0-9]+[[:space:]]*GB?/ {gsub(/[^0-9]/,""); print $1*1024*1024; next}
        /[0-9]+[[:space:]]*MB?/ {gsub(/[^0-9]/,""); print $1*1024; next}
        /[0-9]+[[:space:]]*kB?/ {gsub(/[^0-9]/,""); print $1; next}
        {print $1/1024}
    '
}

# --- Phase 1 ---

phase1_check() {
    log_info "=== Phase 1 Check: EPAS HugePages Configuration ==="

    local huge_pages shared_buffers
    huge_pages=$($PSQL -Atc "SHOW huge_pages;" 2>/dev/null) || { log_error "Cannot connect to database $DB_NAME as $EPAS_USER."; exit 1; }
    shared_buffers=$($PSQL -Atc "SHOW shared_buffers;")

    log_info "huge_pages:      $huge_pages"
    log_info "shared_buffers:  $shared_buffers"

    if [[ "$huge_pages" == "on" ]]; then
        log_info "PASS: huge_pages is 'on'"
    elif [[ "$huge_pages" == "try" ]]; then
        log_warn "WARNING: huge_pages is 'try' — EPAS may silently fall back to normal pages."
        log_info "Recommendation: ALTER SYSTEM SET huge_pages = 'on';"
    elif [[ "$huge_pages" == "off" ]]; then
        log_error "FAIL: huge_pages is 'off'."
        log_info "Run: ALTER SYSTEM SET huge_pages = 'on';"
    fi

    read -r hp_total hp_size_kb hp_total_mb <<< "$(get_os_hugepage_info)"
    log_info "OS HugePages Total: $hp_total pages (${hp_total_mb} MB)"

    local sb_kb sb_pages
    sb_kb=$(parse_shared_buffers_kb "$shared_buffers")
    sb_pages=$(( (sb_kb / hp_size_kb) + 1 + 10 ))
    log_info "shared_buffers requires ~$sb_pages HugePages (with safety buffer)"

    if [[ "$hp_total" -ge "$sb_pages" ]]; then
        log_info "PASS: OS HugePages ($hp_total) >= required ($sb_pages)"
    else
        log_error "FAIL: OS HugePages ($hp_total) < required ($sb_pages)"
        log_error "Action: Inform OS Admin to increase vm.nr_hugepages BEFORE restarting EPAS."
        log_error "Command for OS Admin: ./os_admin_hugepages.sh apply -p ${sb_pages}"
    fi
}

# --- Phase 2 ---

phase2_audit() {
    log_info "=== Phase 2 Audit: Multi-Day Memory Metrics ==="
    local report_file="epas_phase2_audit_$(date +%Y%m%d_%H%M%S).sql"

    cat > "$report_file" <<'SQLEOF'
-- ============================================================
-- EPAS Phase 2 Memory Audit
-- Run during peak hours, save output for trend analysis.
-- ============================================================

\echo '\n>>> 1. TABLE CACHE HIT RATIO (Target >= 99%) <<<'
SELECT
    schemaname || '.' || relname AS table_name,
    heap_blks_read,
    heap_blks_hit,
    CASE WHEN (heap_blks_hit + heap_blks_read) > 0
         THEN round(100.0 * heap_blks_hit / (heap_blks_hit + heap_blks_read), 2)
         ELSE 0 END AS cache_hit_pct
FROM pg_statio_user_tables
WHERE (heap_blks_hit + heap_blks_read) > 0
ORDER BY (heap_blks_hit + heap_blks_read) DESC
LIMIT 20;

\echo '\n>>> 2. INDEX CACHE HIT RATIO (Target >= 99%) <<<'
SELECT
    schemaname || '.' || relname AS table_name,
    indexrelname AS index_name,
    idx_blks_read,
    idx_blks_hit,
    CASE WHEN (idx_blks_hit + idx_blks_read) > 0
         THEN round(100.0 * idx_blks_hit / (idx_blks_hit + idx_blks_read), 2)
         ELSE 0 END AS idx_cache_hit_pct
FROM pg_statio_user_indexes
WHERE (idx_blks_hit + idx_blks_read) > 0
ORDER BY (idx_blks_hit + idx_blks_read) DESC
LIMIT 20;

\echo '\n>>> 3. DISK SPILLS / WORK_MEM PRESSURE <<<'
SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes,
    pg_size_pretty(blks_read * 8192) AS disk_read
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY temp_bytes DESC;

\echo '\n>>> 4. TOP TABLES BY HEAP READS (Cold Cache Indicators) <<<'
SELECT
    schemaname || '.' || relname AS table_name,
    heap_blks_read,
    heap_blks_hit,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC
LIMIT 10;

\echo '\n>>> 5. DRITA SNAPSHOT (EPAS Only) <<<'
-- Ensure DRITA is installed: CREATE EXTENSION IF NOT EXISTS drita;
SELECT edbsnap();
\echo 'DRITA snapshot captured. Run edbreport(prev, curr) after next snapshot.'
SQLEOF

    log_info "Audit SQL saved to: $report_file"
    log_info "Executing audit now..."
    echo ""
    $PSQL -f "$report_file" || true
    echo ""
    log_info "=== Phase 2 Audit Complete ==="
    log_info "Action items:"
    log_info "  - Cache hit ratio < 99%?  Consider increasing shared_buffers."
    log_info "  - temp_files > 0?         Consider tuning work_mem (per-connection cost!)."
    log_info "  - Run this audit multiple times (Days 2-5) during peak load."
    log_info "  - After 2+ DRITA snapshots: SELECT * FROM edbreport(1, 2);"
}

# --- Phase 3 ---

phase3_plan() {
    local target_mb=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m) target_mb="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [[ -z "$target_mb" ]] && usage

    log_info "=== Phase 3 Plan: Capacity Readjustment ==="

    local current_sb
    current_sb=$($PSQL -Atc "SHOW shared_buffers;")
    log_info "Current shared_buffers: $current_sb"
    log_info "Target shared_buffers:  ${target_mb}MB"

    read -r hp_total hp_size_kb hp_total_mb <<< "$(get_os_hugepage_info)"
    local pages_needed pages_current
    pages_needed=$(( (target_mb * 1024 / hp_size_kb) + 1 + 10 ))
    pages_current=$hp_total

    log_info "Current OS HugePages: $pages_current"
    log_info "Required OS HugePages: $pages_needed"

    cat <<EOF

=============================================================
 PHASE 3 READJUSTMENT PLAN  (OS Admin -> DBA -> Restart)
=============================================================
STEP 1 — OS Admin (run as ROOT first!):
   ./os_admin_hugepages.sh apply -p ${pages_needed}
   ./os_admin_hugepages.sh verify -p ${pages_needed}

STEP 2 — DBA (only after OS admin confirms success):
   ALTER SYSTEM SET shared_buffers = '${target_mb}MB';

STEP 3 — SysAdmin or DBA (coordinate maintenance window):
   systemctl restart ${EPAS_SERVICE:-edb-as-17}

STEP 4 — DBA (post-restart verification):
   SHOW shared_buffers;
   SHOW huge_pages;
   SELECT * FROM pg_postmaster_start_time();

CRITICAL: If STEP 1 is skipped or fails, EPAS will FAIL TO START
because huge_pages='on' requires sufficient OS HugePages.
=============================================================
EOF
}

phase3_apply() {
    local target_mb=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m) target_mb="$2"; shift 2 ;;
            *) usage ;;
        esac
    done
    [[ -z "$target_mb" ]] && usage

    log_info "=== Phase 3 Apply: Updating EPAS Configuration ==="

    read -r hp_total hp_size_kb hp_total_mb <<< "$(get_os_hugepage_info)"
    local pages_needed
    pages_needed=$(( (target_mb * 1024 / hp_size_kb) + 1 + 10 ))

    if [[ "$hp_total" -lt "$pages_needed" ]]; then
        log_error "BLOCKED: Insufficient OS HugePages!"
        log_error "Current OS: $hp_total pages | Required: $pages_needed pages"
        log_error "You MUST run the OS Admin step first:"
        log_error "   ./os_admin_hugepages.sh apply -p ${pages_needed}"
        exit 1
    fi

    log_info "OS HugePages sufficient ($hp_total >= $pages_needed)"
    log_info "Executing: ALTER SYSTEM SET shared_buffers = '${target_mb}MB';"
    $PSQL -c "ALTER SYSTEM SET shared_buffers = '${target_mb}MB';"

    log_info "Configuration updated. EPAS restart REQUIRED to activate."
    log_warn "Coordinate restart with OS Admin: systemctl restart ${EPAS_SERVICE:-edb-as-17}"
}

# --- Main ---

[[ $# -eq 0 ]] && usage

COMMAND="$1"
shift

# Parse global opts
while [[ $# -gt 0 ]]; do
    case "$1" in
        -U) EPAS_USER="$2"; PSQL="psql -U $EPAS_USER -d $DB_NAME -v ON_ERROR_STOP=1"; shift 2 ;;
        -d) DB_NAME="$2"; PSQL="psql -U $EPAS_USER -d $DB_NAME -v ON_ERROR_STOP=1"; shift 2 ;;
        *) break ;;
    esac
done

case "$COMMAND" in
    phase1-check) phase1_check ;;
    phase2-audit) phase2_audit ;;
    phase3-plan)  phase3_plan "$@" ;;
    phase3-apply) phase3_apply "$@" ;;
    -h|--help|help) usage ;;
    *) log_error "Unknown command: $COMMAND"; usage ;;
esac
