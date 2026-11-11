# 07-tuning — HugePages & memory tuning (separated duties)

OS administration (root, kernel) is kept separate from database administration (enterprisedb, EPAS config).

| Script | Run as | Purpose |
|---|---|---|
| `setup-epas-kernel.sh [--env conf/site.env] [--user <os_user>] [--yes]` | root | Kernel tuning: HugePages, `hugetlb_shm_group`, overcommit, dirty writeback, THP disable; caps `memlock` at 75 % of RAM (audit policy). HugePages are sized from EPAS itself (`shared_memory_size_in_huge_pages`, running or stopped; `shared_buffers` on older versions; 25 % RAM estimate only as a warned last resort). **Config required**; shows the calculated values and asks before writing `/etc/sysctl.d` and `/etc/security/limits.d`. |
| `dba-epas-verify.sh [--env conf/site.env] [--apply]` | enterprisedb | Validates EPAS against the kernel settings (read-only). `--apply` sets `huge_pages='on'` if needed — requires a config and asks first. |
| `dba-resize-buffers.sh -m <MB> [--env conf/site.env] [--apply]` | enterprisedb | Dry-run plan of a `shared_buffers` change and the HugePages it needs. `--apply` runs `ALTER SYSTEM` — requires a config and asks first. Connects on `PRIMARY_PORT`. |
| `sql/epas-perf-monitor-appdb.sql` | enterprisedb | Installs the performance-monitoring objects in the application database. |
| `sql/epas-daily-memory-io-check.sql` | enterprisedb | Daily memory & I/O health check — run at the same time each day and keep the output. |

Workflow: root runs `setup-epas-kernel.sh` → DBA runs `dba-epas-verify.sh` → after a few days of `sql/epas-daily-memory-io-check.sql` output, DBA plans with `dba-resize-buffers.sh -m <MB>` → root re-runs the kernel script with the new page count → DBA `--apply`.
Day-by-day audit procedure: `../../docs/tuning-multiday-audit.md`.
