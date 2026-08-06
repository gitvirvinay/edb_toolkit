-- ============================================================
-- EPAS Unified Performance Monitoring (On-Prem)
-- Install this in your APPLICATION database (e.g., app_db)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS perf;

-- ============================================================
-- PART A: Real-Time Tables (sampled every 5 minutes)
-- ============================================================

CREATE TABLE IF NOT EXISTS perf.load_history (
    snapshot_time      timestamptz NOT NULL,
    wait_event_type    text,
    wait_event         text,
    active_sessions    int
);

CREATE TABLE IF NOT EXISTS perf.session_history (
    snapshot_time  timestamptz NOT NULL,
    datname        text,
    state          text,
    total          int
);

CREATE TABLE IF NOT EXISTS perf.replication_history (
    snapshot_time                timestamptz NOT NULL,
    server_id                    text,
    session_id                   text,
    lag_ms                       bigint,
    highest_lsn_received         text,
    highest_lsn_replayed         text,
    highest_lsn_replayed_ts      timestamptz,
    last_update_ts               timestamptz,
    replay_delay_seconds         numeric
);

CREATE TABLE IF NOT EXISTS perf.io_history (
    snapshot_time   timestamptz NOT NULL,
    backend_type    text,
    object          text,
    context         text,
    reads           bigint,
    writes          bigint,
    writebacks      bigint,
    extends         bigint,
    hits            bigint
);

CREATE TABLE IF NOT EXISTS perf.checkpoint_history (
    snapshot_time          timestamptz NOT NULL,
    checkpoints_timed      bigint,
    checkpoints_req        bigint,
    checkpoint_write_time  double precision,
    checkpoint_sync_time   double precision,
    buffers_checkpoint     bigint,
    buffers_clean          bigint,
    maxwritten_clean       bigint,
    buffers_backend        bigint,
    buffers_alloc          bigint,
    wal_bytes_generated    numeric
);

CREATE TABLE IF NOT EXISTS perf.top_sql_history (
    snapshot_time       timestamptz NOT NULL,
    queryid             bigint,
    calls               bigint,
    total_exec_time     double precision,
    mean_exec_time      double precision,
    rows                bigint,
    shared_blks_read    bigint,
    shared_blks_hit     bigint,
    temp_blks_read      bigint,
    temp_blks_written   bigint,
    plans               bigint,
    total_plan_time     double precision,
    mean_plan_time      double precision,
    query               text
);

-- ============================================================
-- PART B: Daily Snapshot Tables (cumulative counters, DRITA-style)
-- ============================================================

CREATE TABLE IF NOT EXISTS perf.daily_snapshots (
    snap_id         SERIAL PRIMARY KEY,
    snap_time       timestamptz NOT NULL DEFAULT now(),
    instance_uptime interval NOT NULL
);

CREATE TABLE IF NOT EXISTS perf.snapshot_data (
    snap_id         int REFERENCES perf.daily_snapshots(snap_id),
    category        text NOT NULL,
    object_name     text,
    metric_name     text NOT NULL,
    metric_value    bigint NOT NULL,
    PRIMARY KEY (snap_id, category, object_name, metric_name)
);

-- ============================================================
-- PROCEDURE 1: Real-Time Capture (run every 5 minutes via cron)
-- ============================================================

CREATE OR REPLACE PROCEDURE perf.capture_realtime()
LANGUAGE plpgsql
AS $$
DECLARE 
    snap timestamptz := now();
BEGIN
    -- 1. AAS / LOAD
    INSERT INTO perf.load_history
    SELECT snap, wait_event_type, wait_event, COUNT(*)::int
    FROM pg_stat_activity
    WHERE state <> 'idle'
      AND backend_type = 'client backend'
    GROUP BY wait_event_type, wait_event;

    -- 2. SESSIONS
    INSERT INTO perf.session_history
    SELECT snap, datname, state, COUNT(*)::int
    FROM pg_stat_activity
    GROUP BY datname, state;

    -- 3. REPLICATION HEALTH (EPAS native)
    INSERT INTO perf.replication_history
    SELECT
        snap,
        COALESCE(client_addr::text, 'primary'),
        COALESCE(application_name, 'local'),
        CASE WHEN pg_last_xact_replay_timestamp() IS NOT NULL
             THEN (EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) * 1000)::bigint
             ELSE 0 END,
        COALESCE(sent_lsn::text, '0/0'),
        COALESCE(replay_lsn::text, '0/0'),
        now(),
        now(),
        CASE WHEN pg_last_xact_replay_timestamp() IS NOT NULL
             THEN EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))
             ELSE 0 END
    FROM pg_stat_replication
    UNION ALL
    SELECT snap, 'primary', 'primary', 0, '0/0', '0/0', now(), now(), 0
    WHERE NOT EXISTS (SELECT 1 FROM pg_stat_replication);

    -- 4. IO STATS (PG16+/EPAS17+)
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'pg_stat_io') THEN
        INSERT INTO perf.io_history
        SELECT snap, backend_type, object, context,
               reads, writes, writebacks, extends, hits
        FROM pg_stat_io;
    END IF;

    -- 5. WAL + CHECKPOINTS
    INSERT INTO perf.checkpoint_history
    SELECT
        snap,
        checkpoints_timed,
        checkpoints_req,
        checkpoint_write_time,
        checkpoint_sync_time,
        buffers_checkpoint,
        buffers_clean,
        maxwritten_clean,
        buffers_backend,
        buffers_alloc,
        pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')
    FROM pg_stat_bgwriter;

    -- 6. TOP SQL (application queries from THIS database)
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN
        INSERT INTO perf.top_sql_history
        SELECT
            snap,
            queryid,
            calls,
            total_exec_time,
            mean_exec_time,
            rows,
            shared_blks_read,
            shared_blks_hit,
            temp_blks_read,
            temp_blks_written,
            plans,
            total_plan_time,
            mean_plan_time,
            LEFT(query, 4000)
        FROM pg_stat_statements
        ORDER BY total_exec_time DESC
        LIMIT 20;
    END IF;
END;
$$;

-- ============================================================
-- PROCEDURE 2: Daily Snapshot (run once per day)
-- ============================================================

CREATE OR REPLACE PROCEDURE perf.capture_daily()
LANGUAGE plpgsql
AS $$
DECLARE
    v_snap_id int;
    v_uptime  interval;
BEGIN
    SELECT now() - pg_postmaster_start_time() INTO v_uptime;

    INSERT INTO perf.daily_snapshots (instance_uptime)
    VALUES (v_uptime)
    RETURNING snap_id INTO v_snap_id;

    -- Database-level cumulative stats
    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'database', datname, 'blks_read', blks_read
    FROM pg_stat_database WHERE datname NOT IN ('template0', 'template1');

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'database', datname, 'blks_hit', blks_hit
    FROM pg_stat_database WHERE datname NOT IN ('template0', 'template1');

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'database', datname, 'temp_files', temp_files
    FROM pg_stat_database WHERE datname NOT IN ('template0', 'template1');

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'database', datname, 'temp_bytes', temp_bytes
    FROM pg_stat_database WHERE datname NOT IN ('template0', 'template1');

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'database', datname, 'tup_returned', tup_returned
    FROM pg_stat_database WHERE datname NOT IN ('template0', 'template1');

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'database', datname, 'tup_fetched', tup_fetched
    FROM pg_stat_database WHERE datname NOT IN ('template0', 'template1');

    -- Table I/O stats (top 50 by activity)
    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'table', schemaname || '.' || relname, 'heap_blks_read', heap_blks_read
    FROM pg_statio_user_tables
    ORDER BY heap_blks_read + heap_blks_hit DESC
    LIMIT 50;

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'table', schemaname || '.' || relname, 'heap_blks_hit', heap_blks_hit
    FROM pg_statio_user_tables
    ORDER BY heap_blks_read + heap_blks_hit DESC
    LIMIT 50;

    -- Index I/O stats (top 50)
    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'index', schemaname || '.' || relname || '.' || indexrelname,
           'idx_blks_read', idx_blks_read
    FROM pg_statio_user_indexes
    ORDER BY idx_blks_read + idx_blks_hit DESC
    LIMIT 50;

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'index', schemaname || '.' || relname || '.' || indexrelname,
           'idx_blks_hit', idx_blks_hit
    FROM pg_statio_user_indexes
    ORDER BY idx_blks_read + idx_blks_hit DESC
    LIMIT 50;

    -- BGWriter stats
    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'bgwriter', 'global', 'checkpoints_timed', checkpoints_timed
    FROM pg_stat_bgwriter;

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'bgwriter', 'global', 'checkpoints_req', checkpoints_req
    FROM pg_stat_bgwriter;

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'bgwriter', 'global', 'buffers_checkpoint', buffers_checkpoint
    FROM pg_stat_bgwriter;

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'bgwriter', 'global', 'buffers_clean', buffers_clean
    FROM pg_stat_bgwriter;

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'bgwriter', 'global', 'buffers_backend', buffers_backend
    FROM pg_stat_bgwriter;

    INSERT INTO perf.snapshot_data
    SELECT v_snap_id, 'bgwriter', 'global', 'maxwritten_clean', maxwritten_clean
    FROM pg_stat_bgwriter;
END;
$$;

-- ============================================================
-- FUNCTION: Delta Report
-- Usage: SELECT * FROM perf.delta_report(1, 5);
-- ============================================================

CREATE OR REPLACE FUNCTION perf.delta_report(start_snap int, end_snap int)
RETURNS TABLE (
    category text,
    object_name text,
    metric_name text,
    start_val bigint,
    end_val bigint,
    delta bigint,
    pct_change numeric
)
LANGUAGE sql STABLE
AS $$
    SELECT
        e.category,
        e.object_name,
        e.metric_name,
        COALESCE(s.metric_value, 0) AS start_val,
        e.metric_value AS end_val,
        (e.metric_value - COALESCE(s.metric_value, 0)) AS delta,
        CASE WHEN COALESCE(s.metric_value, 0) > 0
             THEN round(100.0 * (e.metric_value - s.metric_value) / s.metric_value, 2)
             ELSE NULL END AS pct_change
    FROM perf.snapshot_data e
    LEFT JOIN perf.snapshot_data s
        ON e.category = s.category
        AND e.object_name = s.object_name
        AND e.metric_name = s.metric_name
        AND s.snap_id = start_snap
    WHERE e.snap_id = end_snap
      AND (e.metric_value - COALESCE(s.metric_value, 0)) != 0
    ORDER BY e.category, ABS(e.metric_value - COALESCE(s.metric_value, 0)) DESC;
$$;

-- ============================================================
-- VIEWS: Quick Health Checks
-- ============================================================

CREATE OR REPLACE VIEW perf.cache_hit_ratio AS
SELECT
    'tables' AS target,
    round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit + heap_blks_read), 0), 2) AS cache_hit_pct
FROM pg_statio_user_tables
UNION ALL
SELECT
    'indexes',
    round(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit + idx_blks_read), 0), 2)
FROM pg_statio_user_indexes;

CREATE OR REPLACE VIEW perf.latest_sessions AS
SELECT *
FROM perf.session_history
WHERE snapshot_time = (SELECT max(snapshot_time) FROM perf.session_history);

CREATE OR REPLACE VIEW perf.latest_top_sql AS
SELECT *
FROM perf.top_sql_history
WHERE snapshot_time = (SELECT max(snapshot_time) FROM perf.top_sql_history);

-- ============================================================
-- INSTALLATION STEPS
-- ============================================================

-- 1. Connect to your application database:
--    psql -d app_db -p 5444 -U enterprisedb

-- 2. Create extension (one-time):
--    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 3. Run this entire script.

-- 4. Cron jobs (run as enterprisedb or any superuser):
--    */5 * * * * psql -d app_db -p 5444 -c "CALL perf.capture_realtime();"
--    0 0 * * *   psql -d app_db -p 5444 -c "CALL perf.capture_daily();"

-- 5. After 5 days, analyze:
--    SELECT * FROM perf.delta_report(1, 5);
--    SELECT * FROM perf.cache_hit_ratio;
--    SELECT * FROM perf.latest_sessions;