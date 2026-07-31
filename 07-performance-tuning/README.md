# EPAS HugePages Tuning — Separated Duties

This toolkit enforces a clean separation between **OS Administration** (root/kernel) and **Database Administration** (EPAS config/audit).

## Files

| File | User | Purpose |
|------|------|---------|
| `os_admin_hugepages.sh` | `root` | Kernel tuning: `vm.nr_hugepages`, `vm.hugetlb_shm_group`, `memlock`, THP disable. |
| `dba_memory_tuning.sh` | `enterprisedb` (or DBA user) | Config validation, audit SQL, capacity planning, `ALTER SYSTEM`. |
| `phase2_audit_queries.sql` | `enterprisedb` | Standalone SQL for manual multi-day auditing. |

---

## Phase 1 — Lock Infrastructure (Day 1)

### OS Admin (root)
```bash
chmod +x os_admin_hugepages.sh
./os_admin_hugepages.sh setup
```
- Auto-detects running EPAS shared memory
- Calculates + applies `vm.nr_hugepages`
- Sets `vm.hugetlb_shm_group` to `enterprisedb` GID
- Writes `memlock unlimited` to `/etc/security/limits.d/`
- Disables THP (runtime + persistent via `sysctl.d`)
- **Verifies** that the kernel actually allocated the pages

### DBA (`enterprisedb`)
```bash
chmod +x dba_memory_tuning.sh
./dba_memory_tuning.sh phase1-check
```
- Confirms `huge_pages = 'on'` (or warns if `try`/`off`)
- Cross-checks OS HugePages count vs. `shared_buffers` requirement
- If `huge_pages` is not `on`:
  ```sql
  ALTER SYSTEM SET huge_pages = 'on';
  ```

### Restart (coordinate together)
```bash
systemctl restart edb-as-17
```

---

## Phase 2 — Multi-Day Audit (Days 2–5)

### DBA (`enterprisedb`)
Run daily during normal production load:

```bash
./dba_memory_tuning.sh phase2-audit
```

Or run the standalone SQL manually:
```bash
psql -d edb -f phase2_audit_queries.sql
```

#### What to track
| Metric | Source | Target |
|--------|--------|--------|
| Table Cache Hit Ratio | `pg_statio_user_tables` | ≥ 99% |
| Index Cache Hit Ratio | `pg_statio_user_indexes` | ≥ 99% |
| Disk Spills | `pg_stat_database.temp_files` | 0 (or minimal) |
| DRITA Wait Events | `edbsnap()` / `edbreport()` | Baseline & trend |

> **Rule of thumb:** If cache hit ratio is < 95–99% **and** the working set size justifies it, plan a `shared_buffers` increase.

---

## Phase 3 — Capacity Readjustment

**Critical order:** OS first → DBA second → Restart last.

### Step 1: DBA plans the change
```bash
./dba_memory_tuning.sh phase3-plan -m 8192
```
This prints the exact command for the OS admin and warns about restart requirements.

### Step 2: OS Admin applies kernel changes
```bash
./os_admin_hugepages.sh apply -p 4200   # example page count from plan
./os_admin_hugepages.sh verify -p 4200  # confirm allocation
```
> If `verify` fails, **STOP**. Do not let the DBA change `shared_buffers`. Free memory or reboot first.

### Step 3: DBA applies database config
```bash
./dba_memory_tuning.sh phase3-apply -m 8192
```
This internally re-verifies OS HugePages are sufficient, then runs:
```sql
ALTER SYSTEM SET shared_buffers = '8192MB';
```

### Step 4: Restart EPAS
```bash
systemctl restart edb-as-17
```

---

## Safety Design

1. **huge_pages = 'on' is strict.** If OS pages are insufficient, EPAS will refuse to start. The DBA script `phase3-apply` blocks the `ALTER SYSTEM` until the OS side reports enough pages.
2. **No `sudo` in DBA script.** The DBA script never touches `/etc/sysctl.d`, `/proc/sys`, or THP.
3. **No `psql` in OS script.** The OS script never modifies `postgresql.conf` or runs SQL.
4. **Verification gates.** `os_admin_hugepages.sh verify` checks `/proc/meminfo` after `sysctl` to catch allocation failures caused by memory fragmentation.

---

## Customization

Both scripts respect environment variables:

```bash
# OS Admin
EPAS_USER=enterprisedb EPAS_SERVICE=edb-as-16 ./os_admin_hugepages.sh setup

# DBA
EPAS_USER=enterprisedb DB_NAME=mydb ./dba_memory_tuning.sh phase1-check
```
