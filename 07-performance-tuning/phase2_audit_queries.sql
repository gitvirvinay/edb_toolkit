-- ============================================================
-- EPAS Phase 2 Memory Audit Queries
-- Save outputs daily (Days 2-5) under normal production load.
-- ============================================================

-- 1. TABLE CACHE HIT RATIO
-- Target: >= 99%. Low values suggest shared_buffers is too small
-- or the working set exceeds RAM.
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
LIMIT 25;

-- 2. INDEX CACHE HIT RATIO
-- Indexes should typically have even higher hit ratios than tables.
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
LIMIT 25;

-- 3. DISK SPILLS (work_mem pressure indicator)
-- temp_files > 0 means queries are spilling to disk.
-- Do NOT blindly increase work_mem; it is per-operation per-connection.
SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_bytes,
    pg_size_pretty(blks_read * 8192) AS total_disk_read
FROM pg_stat_database
WHERE datname NOT IN ('template0', 'template1')
ORDER BY temp_bytes DESC;

-- 4. TOP TABLES BY PHYSICAL READS
-- Identifies tables/indexes that may benefit from caching or query tuning.
SELECT
    schemaname || '.' || relname AS table_name,
    heap_blks_read,
    heap_blks_hit,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total_size
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC
LIMIT 15;

-- 5. DRITA SNAPSHOT (EPAS only)
-- Requires: CREATE EXTENSION drita;
-- Take snapshots at start/end of peak periods, then compare.
SELECT edbsnap();

-- After collecting 2+ snapshots, generate a report:
-- SELECT * FROM edbreport(1, 2);
