-- ============================================================
-- EPAS Phase 2: Daily Memory & I/O Health Check
-- Run once daily at the same time. Store output for trending.
-- ============================================================

-- 0. TIMESTAMP (include in every output)
SELECT now() AS snapshot_time,
       pg_postmaster_start_time() AS postmaster_start_time,
       extract(epoch FROM (now() - pg_postmaster_start_time()))/3600 AS uptime_hours;

-- 1. CONNECTION LOAD (point-in-time, not cumulative)
SELECT count(*) FILTER (WHERE state = 'active')  AS active,
       count(*) FILTER (WHERE state = 'idle')     AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_xact,
       count(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting_on_lock,
       count(*) AS total
FROM pg_stat_activity
WHERE backend_type = 'client backend';

-- 2. CACHE HIT RATIOS (cumulative since last reset — note the baseline!)
SELECT 'user tables' AS category,
       sum(heap_blks_hit) AS total_hit,
       sum(heap_blks_read) AS total_read,
       round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit + heap_blks_read), 0), 2) AS cache_hit_pct
FROM pg_statio_user_tables
UNION ALL
SELECT 'user indexes',
       sum(idx_blks_hit),
       sum(idx_blks_read),
       round(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit + idx_blks_read), 0), 2)
FROM pg_statio_user_indexes;

-- 3. BGWRITER / CHECKPOINT HEALTH (cumulative)
SELECT checkpoints_timed,
       checkpoints_req,
       round(100.0 * checkpoints_req / nullif(checkpoints_timed + checkpoints_req, 0), 2) AS pct_forced_checkpoints,
       buffers_backend,
       buffers_clean,
       buffers_checkpoint,
       maxwritten_clean
FROM pg_stat_bgwriter;

-- 4. TOP TABLES BY DEAD TUPLES (bloat indicator)
SELECT schemaname || '.' || relname AS table_name,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_vacuum,
       last_autovacuum,
       last_analyze
FROM pg_stat_user_tables
WHERE n_live_tup + n_dead_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 15;

-- 5. DISK SPILL ACTIVITY (cumulative per DB)
SELECT datname,
       temp_files,
       pg_size_pretty(temp_bytes) AS temp_bytes_total,
       CASE WHEN temp_files > 0
            THEN pg_size_pretty(temp_bytes / temp_files)
            ELSE '0 bytes' END AS avg_temp_file_size
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY temp_bytes DESC;

-- 6. DRITA SNAPSHOT (EPAS only — the proper way to trend performance)
--With EPAS 17, DRITA is deprecated and will be removed in EPAS 18. EDB
-- Run this at the START of a peak window.
-- Take a snapshot (returns an ID number)
SELECT edbsnap();

-- Later, take another snapshot
SELECT edbsnap();

-- Generate a report comparing snapshot 1 to 2
SELECT * FROM edbreport(1, 2);

-- Run this at the END of the peak window, then generate the report:
-- SELECT * FROM edbreport(<start_snap_id>, <end_snap_id>);

