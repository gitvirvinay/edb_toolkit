Here is the exact day-by-day workflow to prove whether the kernel tuning worked.

---

## Step 1: Prerequisites (One-Time, Before Day 1)

Connect to your application database as `enterprisedb`:

```bash
psql -d app_db -p 5444 -U enterprisedb
```

Run this inside `psql`:

```sql
-- Required for Top SQL tracking
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Optional: reset stats so Day 1 starts clean
-- Only do this if you can afford losing historical stats
SELECT pg_stat_reset();
SELECT pg_stat_statements_reset();
```

---

## Step 2: Install the Monitoring Schema (One-Time)

```bash
psql -d app_db -p 5444 -U enterprisedb -f epas_perf_monitor_appdb.sql
```

This creates the `perf` schema with all tables, procedures, and views.

---

## Step 3: Set Up Cron (Before Day 1)

As the `enterprisedb` OS user:

```bash
crontab -e
```

Add these two lines:

```cron
# Real-time sample every 5 minutes
*/5 * * * * psql -d app_db -p 5444 -tc "CALL perf.capture_realtime();" >/dev/null 2>&1

# Daily cumulative snapshot at 00:00
0 0 * * * psql -d app_db -p 5444 -tc "CALL perf.capture_daily();" >/dev/null 2>&1
```

Verify it works manually first:

```sql
CALL perf.capture_realtime();
CALL perf.capture_daily();
```

---

## Step 4: The 5-Day Timeline

| Day       | What Happens                                            | Your Action                                      |
| --------- | ------------------------------------------------------- | ------------------------------------------------ |
| **Day 0** | Baseline established                                    | Install schema, verify cron, let normal load run |
| **Day 1** | First daily snapshot captured automatically at midnight | None                                             |
| **Day 2** | Second snapshot                                         | None                                             |
| **Day 3** | Third snapshot                                          | None                                             |
| **Day 4** | Fourth snapshot                                         | None                                             |
| **Day 5** | Fifth snapshot                                          | Run analysis queries (see below)                 |


> **Important:** Do **not** restart EPAS or the OS during these 5 days unless necessary. A restart resets cumulative counters and invalidates the delta.

---

## Step 5: Day 5 Analysis

Connect to `app_db` and run these queries in order.

### 5.1 Verify snapshots exist

```sql
SELECT snap_id, snap_time, instance_uptime
FROM perf.daily_snapshots
ORDER BY snap_id;
```

You should see 5 rows. If you see fewer, your cron is not firing.

### 5.2 The Big Delta Report

```sql
SELECT * FROM perf.delta_report(1, 5);
```

This shows every metric that changed between Day 1 and Day 5. Look for these specific rows:

| Category   | Metric            | What Improvement Looks Like                               |
| ---------- | ----------------- | --------------------------------------------------------- |
| `database` | `blks_hit`        | Increased significantly                                   |
| `database` | `blks_read`       | **Decreased** or grew slower than `blks_hit`              |
| `database` | `temp_files`      | **Decreased** (fewer work\_mem spills)                    |
| `database` | `temp_bytes`      | **Decreased**                                             |
| `table`    | `heap_blks_read`  | **Decreased** on hot tables                               |
| `index`    | `idx_blks_read`   | **Decreased** on hot indexes                              |
| `bgwriter` | `checkpoints_req` | **Decreased** (fewer forced checkpoints)                  |
| `bgwriter` | `buffers_backend` | **Decreased** (backend writes less, checkpoint does more) |


### 5.3 Cache Hit Ratio (Point-in-Time)

```sql
SELECT * FROM perf.cache_hit_ratio;
```

Compare this to what you saw on Day 1. After HugePages + dirty ratio tuning:

- **Tables:** Should be ≥ 99%
- **Indexes:** Should be ≥ 99.5%

If these were already high on Day 1, the kernel tuning prevented degradation rather than creating a visible jump.

### 5.4 Checkpoint Health

```sql
SELECT 
    snapshot_time,
    checkpoints_timed,
    checkpoints_req,
    round(100.0 * checkpoints_req / nullif(checkpoints_timed + checkpoints_req, 0), 2) AS pct_forced,
    pg_size_pretty(wal_bytes_generated) AS wal_total
FROM perf.checkpoint_history
ORDER BY snapshot_time;
```

**What you want to see:** `pct_forced` trending down. The `vm.dirty_ratio = 10` tuning should make checkpoints more predictable and reduce "emergency" checkpoints.

### 5.5 Session Load Trend

```sql
SELECT 
    date_trunc('hour', snapshot_time) AS hour,
    avg(total) FILTER (WHERE state = 'active') AS avg_active,
    max(total) FILTER (WHERE state = 'active') AS peak_active,
    avg(total) FILTER (WHERE wait_event_type = 'IO') AS avg_io_waiting
FROM perf.session_history
GROUP BY 1
ORDER BY 1;
```

**What you want:** `avg_io_waiting` should decrease or stay flat despite load. If active sessions stay the same but IO waits drop, the dirty-page tuning is working.

### 5.6 Top SQL Comparison (Optional but Powerful)

```sql
-- Day 1 Top SQL
SELECT queryid, mean_exec_time, calls, temp_blks_written
FROM perf.top_sql_history
WHERE snapshot_time = (SELECT min(snapshot_time) FROM perf.top_sql_history)
ORDER BY mean_exec_time DESC
LIMIT 5;

-- Day 5 Top SQL  
SELECT queryid, mean_exec_time, calls, temp_blks_written
FROM perf.top_sql_history
WHERE snapshot_time = (SELECT max(snapshot_time) FROM perf.top_sql_history)
ORDER BY mean_exec_time DESC
LIMIT 5;
```

Look for the same `queryid` values. If `mean_exec_time` and `temp_blks_written` dropped for your heaviest queries, the tuning helped.

---

## Step 6: How to Interpret "Success"

| Observation | Verdict |
|-------------|---------|
| `blks_read` down, `blks_hit` up, cache ratio stable/high | **HugePages are working** — shared buffers are staying resident |
| `temp_files` / `temp_bytes` down | **Overcommit + dirty ratios helped** — less memory pressure, less spilling |
| `checkpoints_req` down | **Dirty ratio tuning worked** — smoother writeback, fewer forced checkpoints |
| No change in any metric | **Working set already fit in RAM** — tuning is preventive, not transformative |
| `blks_read` up, `temp_files` up | **Something else is wrong** — check for new queries, table bloat, or a restart that reset stats |

---

## Quick Day 5 "Executive Summary" Query

Run this single query for a one-page summary:

```sql
WITH cache AS (
    SELECT round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit + heap_blks_read), 0), 2) AS table_hit,
           round(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit + idx_blks_read), 0), 2) AS idx_hit
    FROM pg_statio_user_tables, pg_statio_user_indexes
),
delta AS (
    SELECT * FROM perf.delta_report(1, 5)
),
summary AS (
    SELECT 
        (SELECT table_hit FROM cache) AS current_table_cache_pct,
        (SELECT idx_hit FROM cache) AS current_index_cache_pct,
        (SELECT delta FROM delta WHERE category = 'database' AND metric_name = 'blks_read') AS delta_blks_read,
        (SELECT delta FROM delta WHERE category = 'database' AND metric_name = 'temp_files') AS delta_temp_files,
        (SELECT delta FROM delta WHERE category = 'bgwriter' AND metric_name = 'checkpoints_req') AS delta_forced_ckpt
)
SELECT * FROM summary;
```

**Bottom line:** Install once, let cron run for 5 days, then run the delta report and checkpoint history queries. If `blks_read`, `temp_files`, and forced checkpoints are down while cache ratios stay high, `setup_epas_kernel.sh` did its job.