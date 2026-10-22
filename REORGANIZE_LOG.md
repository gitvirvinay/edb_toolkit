# edb_toolkit cleanup log (2026-10-17)

Plain file operations, not committed. Deleted files remain in git history (`git checkout HEAD -- <path>` restores them).

## Deleted (redundant / superseded)

- `old_automation` — earlier generation (EPAS 15-specific) of the patching, upgrade and standby-rebuild scripts, superseded by 01-/03-/04-
- `07-performance-tuning/setup_epas_kernel.sh` — older copy; the newer `_v1` (memlock capped at 75% RAM per audit policy) is kept as setup-epas-kernel.sh

## Renamed / moved

- `01-provisioning-engine/deploy.env.txt` → `01-provisioning-engine/deploy.env.example`
- `01-provisioning-engine/dnf-install-recommendation.txt` → `01-provisioning-engine/dnf-install-recommendation.md`
- `01-provisioning-engine/epas-base-build_symlink.sh` → `01-provisioning-engine/epas-base-build-symlink-layout.sh`
- `01-provisioning-engine/sudo-sample.txt` → `01-provisioning-engine/sudoers-deployer.sample`
- `02-security-ssl/generate-selfsigned_SAN.sh` → `02-security-ssl/generate-selfsigned-san.sh`
- `02-security-ssl/generate-selfsigned_single.sh` → `02-security-ssl/generate-selfsigned-single.sh`
- `03-lifecycle-patching/epas_minor_patchupdate.sh` → `03-lifecycle-patching/epas-minor-patch-update.sh`
- `09-minor-patchset/epas-patchset-upgrade-efm-env.sh` → `03-lifecycle-patching/efm-rolling-minor-patch.sh`
- `04-major-upgrades/README.md.md` → `04-major-upgrades/README.md`
- `04-major-upgrades/epas-major-pgupgrade.sh.sh` → `04-major-upgrades/epas-major-pgupgrade.sh`
- `04-major-upgrades/sudo_4_upgrade` → `04-major-upgrades/sudoers-upgrade-epas14-to-17.sample`
- `05-high-availability-efm/efm-interactive-cluster-setup@server.sh` → `05-high-availability-efm/efm-interactive-cluster-setup.sh`
- `05-high-availability-efm/efm_migrate_config.sh` → `05-high-availability-efm/efm-reconfigure-for-epas17.sh`
- `07-performance-tuning/setup_epas_kernel_v1.sh` → `07-performance-tuning/setup-epas-kernel.sh`
- `07-performance-tuning/dba_epas_verify.sh` → `07-performance-tuning/dba-epas-verify.sh`
- `07-performance-tuning/dba_resize_buffers.sh` → `07-performance-tuning/dba-resize-buffers.sh`
- `07-performance-tuning/dba_multiday_audit.md` → `07-performance-tuning/dba-multiday-audit.md`
- `07-performance-tuning/epas_perf_monitor_appdb.sql` → `07-performance-tuning/epas-perf-monitor-appdb.sql`
- `07-performance-tuning/misc/epas_manual_monitor_miscellanous.sql` → `07-performance-tuning/epas-daily-memory-io-check.sql`
- `07-performance-tuning/deploy.env.txt` → `07-performance-tuning/deploy.env.example`
- `08-tde-thales/deploy.env` → `08-tde-thales/deploy.env.example`
- `08-tde-thales/migrate.env` → `08-tde-thales/migrate.env.example`
- `04-major-upgrades/README.md`: removed the stray ```markdown code-fence wrapper so it renders

## References updated

- `02-security-ssl/README.md` — file names updated to match renames
- `07-performance-tuning/dba-epas-verify.sh` — file names updated to match renames
- `07-performance-tuning/dba-multiday-audit.md` — file names updated to match renames
- `07-performance-tuning/dba-resize-buffers.sh` — file names updated to match renames
- `07-performance-tuning/setup-epas-kernel.sh` — file names updated to match renames

## Docs

- `README.md`: fixed module table (02-security-ssl, added 08-tde-thales, config/, get-edb-inventory.sh) and env-template note
- `08-tde-thales/README.md`: added `cp *.env.example` step
- added `.gitignore` for real `deploy.env` / `config.env` / `migrate.env`

## Step 1 restructure (2026-10-17): modules/ + lib/ + conf/ + docs/ + tools/ + tests/

- `01-provisioning-engine` → `modules/01-provision`
- `02-security-ssl` → `modules/02-ssl`
- `03-lifecycle-patching` → `modules/03-patching`
- `04-major-upgrades` → `modules/04-upgrade`
- `05-high-availability-efm` → `modules/05-efm`
- `06-backup-recovery` → `modules/06-backup`
- `07-performance-tuning` → `modules/07-tuning`
- `08-tde-thales` → `modules/08-tde`
- `config/logger.sh` → `lib/logger.sh`
- `config/sudoers.d/epas-automation` → `conf/sudoers.d/epas-automation`
- `modules/01-provision/sudoers-deployer.sample` → `conf/sudoers.d/deployer.sample`
- `modules/04-upgrade/sudoers-upgrade-epas14-to-17.sample` → `conf/sudoers.d/upgrade-epas14-to-17.sample`
- `modules/01-provision/dnf-install-recommendation.md` → `docs/dnf-install-recommendation.md`
- `modules/07-tuning/dba-multiday-audit.md` → `docs/tuning-multiday-audit.md`
- `modules/07-tuning/epas-perf-monitor-appdb.sql` → `modules/07-tuning/sql/epas-perf-monitor-appdb.sql`
- `modules/07-tuning/epas-daily-memory-io-check.sql` → `modules/07-tuning/sql/epas-daily-memory-io-check.sql`
- `get-edb-inventory.sh` → `tools/get-edb-inventory.sh`
- `modules/01-provision/deploy.env.example` — merged into `conf/site.env.example` / `conf/tde.env.example`
- `modules/02-ssl/deploy.env.example` — merged into `conf/site.env.example` / `conf/tde.env.example`
- `modules/07-tuning/deploy.env.example` — merged into `conf/site.env.example` / `conf/tde.env.example`
- `modules/03-patching/config.env.example` — merged into `conf/site.env.example` / `conf/tde.env.example`
- `modules/08-tde/deploy.env.example` — merged into `conf/site.env.example` / `conf/tde.env.example`
- `modules/08-tde/migrate.env.example` — merged into `conf/site.env.example` / `conf/tde.env.example`
- `conf/site.env.example`: single shared template replacing the 01/02/07 `deploy.env.example` and 03 `config.env.example`. Conflicts resolved: `SECURITY_TOP=${DATA_TOP}/security` (02 & generate-env.sh), `REP_SLOT_NAME` from local hostname (01/02 & generate-env.sh; 07's standby-based form kept as a comment), TDE passphrase read from `$TDE_PASSPHRASE` (07). Added `EFM_VERSION`, `EPAS_SERVICE`, `EFM_SERVICE` (from 03).
- `conf/tde.env.example`: replaces 08 `deploy.env.example` + `migrate.env.example`; sources `conf/site.env` then adds Thales/KMIP settings and `OLD_TDE_PASSPHRASE`. Note: 08 previously used package-default paths (`/usr/edb/as17`, `/var/lib/edb-as/17/data`); it now inherits the site paths.
- Scripts: logger path → `lib/logger.sh`; 03 site scripts now load `conf/site.env` relative to the script (previously `../config.env` relative to the current directory, which only worked when run from inside the site folder); help/usage text points to `conf/site.env` / `conf/tde.env`. No other logic changed.
- Line endings: 11 files converted CRLF → LF in the working copy (git already stored LF); `.gitattributes` now enforces LF for scripts, SQL and env templates. All 33 scripts pass `bash -n`.
- Docs: new READMEs for 01, 03, 05, 06; 07 README rewritten (it described scripts that no longer exist); 02/04/08 READMEs updated for new paths (04 also referenced a non-existent `epas-major-pgupgrade-unified.sh`); top-level README rewritten.
- Added `tests/lint.sh`, `Makefile` (lint, env, inventory) and `.github/workflows/lint.yml`.
- Known, left for step 2: 01 scripts take the env file as `$1` although help says `--env`; hard-coded EPAS/EFM versions in 04/05; 14 scripts with their own log helpers instead of `lib/logger.sh`.

## Step 2, batch 1 (2026-10-17): lib/common.sh + low-risk scripts

- Added `lib/common.sh`: `parse_common_args` (`--env f`, `--env=f`, or first argument `*.env`), `load_env required|optional` (explicit file → repo `conf/site.env` → stop or warn+defaults), version-derived defaults (`SERVICE_NAME=edb-as-${EPAS_VERSION}`, `EFM_SERVICE=edb-efm-${EFM_VERSION}`, …), `show_config` (prints values, masks *PASS*/*SECRET*/*TOKEN*), `require_vars`, `require_root`, `die`.
- `lib/logger.sh`: `sudo -n` (never hangs on a password prompt) and quiet fallbacks.
- Migrated (start-up only; the actual checks/commands are unchanged):
  - `modules/05-efm/efm-cluster-status.sh` — config optional; cluster name from `EFM_CLUSTER_NAME`; `--help`; unknown options rejected.
  - `modules/06-backup/pgbackrest-validate.sh` — config optional; `STANZA` from config; `--help`.
  - `modules/06-backup/take-prepatch-snapshot.sh` — config optional; service from `EPAS_VERSION` (was hard-coded edb-as-17); `--help`; a failure to write `snapshots.log` after a successful backup is now a warning instead of exit 1; `hostname -f` falls back to `hostname`.
  - `modules/07-tuning/dba-epas-verify.sh` — config via common (was `--env` only, hard-coded edb-as-17); unknown option now stops instead of being counted as a FAIL; adds an audit-log summary line.
- `conf/site.env.example`: added `STANZA`, `EFM_CLUSTER_NAME`.
- All scripts set executable (git stored them as 644, so `./script.sh` failed after clone).
- Dry-tested with stubbed sudo/systemctl/pgbackrest/efm/psql: --help, no config (warning + defaults), EPAS 15 config (service edb-as-15, stanza prod used), --env / --env= / positional, missing file and unknown option (clean error).

## Step 2, batch 2 (2026-10-17): 03-patching

- `lib/common.sh`: added `--yes`/`-y`, `confirm_or_exit` (prompts only on a terminal), `wait_for_epas` (pg_isready **with `-p PRIMARY_PORT`** as `SYSTEM_USER`, using `${SRC_BINARY_DIR}/bin/pg_isready`), `efm_bin` (`/usr/edb/efm-${EFM_VERSION}/bin/efm`), default `EFM_CLUSTER_NAME`.
- `conf/site.env.example`: added `VIP_INTERFACE`, `VIP_ADDRESS`.
- All six 03 scripts: config **required**, settings summary, confirmation, `--help`, unknown options rejected; no hard-coded `edb-as-17` / `edb-efm-5.3` / `enterprisedb` / cluster `efm`.
- Fixes:
  - `pg_isready` had no port, so it checked 5432 and never saw EPAS on 5444; startup scripts then waited 60 s and started EFM anyway. Now checks `PRIMARY_PORT` and **stops without starting EFM** if EPAS is not up.
  - `epas-minor-patch-update.sh` and `efm-rolling-minor-patch.sh` ran `dnf` without root while using sudo elsewhere; both now require root up front. Minor-patch version defaults to `EPAS_VERSION`.
  - `efm` is called by full path for `EFM_VERSION` (was assumed on PATH); `05-efm/efm-cluster-status.sh` updated the same way.
- Dry-tested with stubs: no config (stops), EPAS 15 + cluster prodclu (all commands use them), EPAS never ready (stops, EFM not started), version default/explicit/invalid, interactive "n" (cancelled, nothing run).
- Rolling patch (approved): Phase 2 now stops only the local EFM agent (`systemctl stop ${EFM_SERVICE}`) instead of `efm stop-cluster` (which stopped EFM on every node); Phase 4 upgrades only `edb-as${EPAS_VERSION}*` instead of every installed EPAS version (`edb-as*`).

## Step 2, batch 3 (2026-10-17): 07-tuning

- `setup-epas-kernel.sh`: config **required**; `--user` still overrides `SYSTEM_USER`; root check after `--help`; its messages now go through `lib/logger.sh` (console + file + syslog); shows the calculated HugePages/overcommit/memlock values and **asks before writing** `/etc/sysctl.d/99-${SERVICE_NAME}-kernel.conf` and `/etc/security/limits.d/99-${SERVICE_NAME}-memlock.conf`; audit-log line with the applied values.
- `dba-resize-buffers.sh`: `psql` now uses `-p PRIMARY_PORT` (was default 5432); `-m` validated as a positive number; `--env` no longer silently ignored when the file is missing; dry-run may use defaults (with warning), `--apply` requires a config and asks first; `--help` exits 0; audit-log line on apply.
- `dba-epas-verify.sh`: `--apply` (ALTER SYSTEM huge_pages) now requires a config and asks first; plain verification still runs with defaults.
- Dry-tested: no config (kernel stops), EPAS 15 → files named `99-edb-as-15-*`, answer "n" → nothing written, `--yes --user dbadmin` → memlock lines for dbadmin, resize `-m abc` rejected, dry-run uses `-p 5444`, `--apply` without config stops.
- HugePages fixes (approved):
  1. `setup-epas-kernel.sh` no longer uses `ipcs -m` (EPAS 15/17 shared_buffers live in mmap memory; ipcs saw only a ~56-byte segment → `vm.nr_hugepages = 20`). Size now comes from EPAS: running 15+ `SHOW shared_memory_size_in_huge_pages` → stopped 15+ `edb-postgres -D $DATA_TOP -C shared_memory_size_in_huge_pages` → running <15 `shared_buffers` → last resort 25% of RAM with a warning. The source used is printed, shown in the confirmation and written to the audit log. Headroom unchanged (+10% +20 pages).
  2. `dba-epas-verify.sh` check 3 now sums `Shared_Hugetlb`/`Private_Hugetlb` from the postmaster's smaps. The old pattern `AnonymousHugePages` never matched any field (the THP field is `AnonHugePages`), so it always reported 0.
  - Tested all four sizing paths with a stubbed EPAS (running 15+: 1100 pages → 1230; stopped: 2200 → 2440; <15 with 8 GB shared_buffers: 4096 → 4525; unreachable: 25% estimate + warning) and the smaps check on sample data (8 GB hugetlb detected; old pattern returned 0).

## Step 2, batch 4 (2026-10-17): 01-provision

- All five scripts on `lib/common.sh`: config required, `--env f` / `--env=f` / positional, settings summary, confirmation, `--help`, unknown options rejected, audit-log line at the end. (Correction to an earlier note: the build/prep/rebuild scripts already accepted `--env`.)
- **`epas-rebuild-standby.sh` — critical fix:** the cleanup trap (`rm -rf "$DATA_TOP"`) was armed at the very top, so ANY early exit — wrong OS user, primary unreachable for the slot check, or cancelling — deleted the LIVE data directory before it had been moved aside. The trap is now armed only after the old directory has been moved to `DATA_TOP_bak_<ts>` and a fresh one created. Added a guard: refuses to run if the local EPAS is up and `pg_is_in_recovery()` is false (i.e. on the primary).
  - Tested: wrong user, running primary, unreachable primary, answering "n" → live data intact in all cases; pg_basebackup failure → partial copy removed, previous data kept in `_bak`; success → `standby.signal` present, previous data kept.
- `epas-base-build.sh`: `port` in conf.d now from `PRIMARY_PORT` (was hard-coded 5444); guard against `BINARY_TOP` = `SRC_BINARY_DIR` (the binary rotation would move the EDB install away). Tested: port 5445 written, TDE placeholder still blocks initdb.
- `epas-prep-primary.sh`: warns that the generated replication password must be copied to the standby's `~/.pgpass`.
- `generate-env.sh`: default output `conf/site.env`; never overwrites silently (asks, or `--force` with `.bak_<ts>`); output built from `conf/site.env.example` so it includes all current settings (EFM, STANZA, VIP, TDE_PASSPHRASE form); `eval` replaced by `printf -v`; result syntax-checked. Tested: generated file sources cleanly; second run without `--force` refused; `--force` kept a backup.
- Found, NOT changed (decision needed): `epas-base-build.sh` preloads `pgaudit` and `pg_cron` although their packages are commented out (EPAS would refuse to start), and labels `edb_wait_states.retention_period = 7776000` as "7 Days" (it is 90 days). The symlink-layout script already has both right.
- **Retired `modules/01-provision/epas-base-build.sh`** (decision 2026-10-17): `epas-base-build-symlink-layout.sh` is now the only Day-1 build (re-run safe, never overwrites edited conf.d, memory sized to host, correct preload list). The retired script remains in git history (`git checkout HEAD -- 01-provisioning-engine/epas-base-build.sh`). References updated in README.md, modules/01-provision/README.md, generate-env.sh, modules/08-tde/README.md. Added the `BINARY_TOP` = `SRC_BINARY_DIR` guard to the symlink-layout script as well.
- Renamed `epas-base-build-symlink-layout.sh` → `epas-base-build.sh` (the single Day-1 build; standard name). References updated.

## Step 2, batch 5 (2026-10-17): 02-ssl

- `epas-ssl-setup.sh`: on `lib/common.sh` (config auto-loaded, `--env` optional), root required, `require_vars` incl. `BINARY_TOP`, settings summary + confirmation before any file is written, all `FATAL … exit 1` → `die`, audit-log line.
  - **Config validation fixed:** used `pg_ctl … check` — pg_ctl has no `check` mode, so it always failed and was ignored ("proceeding anyway"), and pg_ctl was looked up on root's PATH. Now `${BINARY_TOP}/bin/edb-postgres -D DATA_TOP -C ssl_cert_file` as `SYSTEM_USER`; if EPAS rejects the config the script **stops before restarting** and points to the backup.
  - Tested with a real encrypted openssl bundle: files installed, chain verified, single restart, old pg_hba backed up; rejected config → no restart; unencrypted key refused.
- `tests/preflight-check.sh`: read the passphrase from `.passphrase`, but setup writes `.ssl_key_passphrase` → key check could never succeed. Fixed (tested: SUCCESS on installed files); usage message if no argument.
- `tests/verify-db-ssl.sh`: uses `lib/common.sh` (auto-loads `conf/site.env`).
- `generate-selfsigned-san.sh`: hosts were hard-coded (server1/server2.example.com, 192.168.1.11/.12); now IPs from `PRIMARY_HOST`/`STANDBY_HOST`, DNS from new `PRIMARY_FQDN`/`STANDBY_FQDN` (IP-only SANs if empty). Tested: SAN = DNS:db1.corp.local, IP:192.168.1.11, IP:192.168.1.12.
- `generate-selfsigned-single.sh`: header name fixed, `--help`, hostname fallback.
- `epas-migrate-ssl-conf.sh`: defaults from config (new = `DATA_TOP`, user = `SYSTEM_USER`, old = `/…/as${OLD_EPAS_VERSION:-15}`) instead of fixed `/pgdata/as15|17`; existing `ssl.conf` backed up before overwrite; note about relative file names; correct group in chown.
- `conf/site.env.example`: added `PRIMARY_FQDN`, `STANDBY_FQDN`.
- Decisions applied (approved): 
  1. **pg_hba.conf merge instead of replace:** SSL rules in a marked block at the top, all existing rules kept below, re-run replaces only the block; added `hostnossl replication all SUBNET_CIDR reject`. Tested: two runs → one block, all 3 custom rules kept.
  2. **Automatic rollback:** if the service does not start after the restart, all replaced files (ssl.conf, pg_hba.conf, key, certs) are restored, a newly created ssl.conf is moved aside, the service is restarted and the run ends with an error explaining what happened; failed files kept in `.backup-<ts>/failed-new-files`. If the rollback restart also fails, a clear "service is DOWN" error. Tested both cases (pg_hba identical to the original after rollback).

## Step 2, batch 6 (2026-10-17): 04-upgrade

- `conf/site.env.example`: new "old cluster" section — `OLD_EPAS_VERSION`, `OLD_SERVICE_NAME`, `OLD_SRC_BINARY_DIR`, `OLD_DATA_TOP`, `OLD_PORT` (also used by 02 `epas-migrate-ssl-conf.sh`).
- `epas-major-pgupgrade.sh` (rewritten start-up, same steps):
  - config required; old cluster from config (was hard-coded edb-as-14, /usr/edb/as14, /pgdata/as14/data);
  - **fixed NEW_DATA = `${DATA_TOP}/data`** → now `DATA_TOP` (it IS the data directory);
  - sanity checks: old version < new, binaries present, both clusters initialised;
  - TDE detected via `pg_encryption/key.bin`; `--link` refused for encrypted clusters (matches the toolkit's own README rule);
  - typed TDE passphrase file now readable by SYSTEM_USER in `--root` mode (was root-only 600 → pg_upgrade could not read it);
  - `--yes` accepted for the backup question (recorded in the audit log); final go-ahead via `confirm_or_exit`;
  - pg_upgrade failure after stopping services: new service not started, clear recovery instructions;
  - waits for the new service (`wait_for_epas`) and **rebuilds statistics with `vacuumdb --all --analyze-in-stages`** (pg_upgrade 14+ does not generate `analyze_new_cluster.sh`, so statistics were never rebuilt).
  - Tested in a sandbox: no config, bad versions, TDE+--link, success (exact command sequence) and pg_upgrade failure.
- **TDE `--copy-by-block` (approved):** added automatically when either cluster is encrypted (EDB docs: required when old/new clusters have different encryption settings or keys; the new cluster from 01 has its own key). Shown in the settings summary as `MODE_STR=copy-by-block`. Tested: both TDE → `--copy-by-block` on --check and the real run; no TDE → not added.
- **`epas-major-pgrestore.sh` rewritten (user chose rewrite over retire).** The old version could not complete a run (wrote conf.d before initdb, invalid `--data-encryption-algorithm`, TDE passphrase via `PGPASSWORD`, never started the new cluster, preloaded pgaudit/pg_cron, skipped `edb`, unencrypted dumps in /tmp, hard-coded 14→17 paths/ports). New version: config from common.sh; new cluster comes from 01 (same as pg_upgrade path, so no initdb/TDE/conf.d here and no passphrase needed); runs as SYSTEM_USER or `--root`; checks real server versions on both ports, empty target, extension availability + pg_cron/pgaudit preload, disk space, other sessions, TDE→non-TDE (refused unless `--allow-unencrypted-target`); globals, then per-database `pg_dump -Fd -j` / `pg_restore -j` (`--create` for new DBs; database-level settings copied for postgres/edb); vacuumdb; old-vs-new object-count comparison; per-DB logs, exit 1 + kept dumps on any failure, `--db` to re-run individual databases; dump dir 700/umask 077, never /tmp, removed after success unless `--keep-dumps`.
  - Tested against two real PostgreSQL 16 clusters (old version check patched in the test copy only): rows, sequence position, functions, extension, large object, DB owner/comment/settings, per-role-in-DB setting, SCRAM password hash, statistics — all match; DB names with a space and an apostrophe work; root-without-`--root`, wrong version on port, unknown `--db`, `/tmp` dump dir, TDE→plain target, re-run into a restored cluster all refused; a forced restore error is reported (exit 1, dumps kept) and a `--db` re-run then completes; non-root run as the OS user works.
  - Bugs found during testing and fixed: database-level settings for postgres/edb were silently not copied (`pg_dump --schema` with no match exits with an error; now `--exclude-schema='*'`), and client-tool errors (`pg_dump: error:`) weren't counted (counter now case-insensitive).

## Batch 7 — 05-efm setup scripts (step 2)

Checked against EDB's EFM docs ("Using the efm utility", "Controlling the Failover Manager service", "The cluster
properties file", "Running multiple agents on a single node"). Both setup scripts were ~85 % identical and could not
produce a working agent:
- their systemd units ran `efm start/stop/reload <cluster>` — the `efm` utility has no such commands;
- they wrote `pid.file`, `log.file`, `cluster.name` — not EFM properties (real ones: `pid.dir`, `log.dir`; the cluster name is the file name);
- the next-steps text used `efm encrypt --from-properties` — the real option is `--from-env` (EFMPASS);
- `efm-interactive-cluster-setup.sh` put the files in `/etc/edb/efm-X.Y/<cluster>/`, where `efm` does not look;
- the README called `efm-multi-cluster-setup.sh` non-interactive (it prompted for everything).

Changes:
- **New `efm-setup.sh`** replaces both (deleted): EDB layout `/etc/edb/efm-<ver>/<cluster>.properties|.nodes` from the
  package templates; packaged unit for cluster `efm`, otherwise a copy as `efm-<cluster>.service` with only
  `CLUSTER=`/`PIDFile=` changed (EDB's documented method); defaults from `conf/site.env`, prompts with defaults,
  `--yes` for automation (`--role` then required); password via `efm encrypt --from-env` (EFMPASS or prompt), kept on
  re-run; port-clash check against other clusters on the node; ping.server.ip / user.email / VIP from config;
  warns when `EFM_SERVICE` doesn't match the unit; prints the exact allow-node / firewall / pg_hba next steps.
- **`efm-reconfigure-for-epas17.sh` → `efm-reconfigure-after-upgrade.sh`**: used `/usr/edb/epas17/bin` and
  `/var/lib/edb/epas17/data` (don't exist; EDB uses `as17`) and EFM 4.8 in the hints. Now from config (`SRC_BINARY_DIR/bin`,
  `DATA_TOP`, `PRIMARY_PORT`, `SERVICE_NAME`), default file from `EFM_VERSION`/`EFM_CLUSTER_NAME`, witness-aware,
  updates `db.config.dir` only if it followed the data dir, backup + diff, correct unit name in the hints.
- `lib/common.sh`: `set_property` / `get_property` (exact key match, value written verbatim, keeps file mode).
- `conf/site.env.example`: `WITNESS_HOST`, `EFM_DB_USER`, `EFM_DB_NAME`, `EFM_BIND_PORT`, `EFM_ADMIN_PORT` (7809, EDB default),
  `EFM_PING_SERVER_IP`, `EFM_USER_EMAIL`, `VIP_PREFIX`, and a note on `EFM_SERVICE` for non-default cluster names.
- Tested (sandbox: stand-in templates/unit, efm/dnf/rpm/systemctl stubs): primary with --yes + EFMPASS; --yes without
  --role refused; second cluster with clashing ports refused; second cluster with own ports → correct unit diff;
  re-run as witness keeps the encrypted password and backs up both files; full interactive run on a real TTY;
  reconfigure: correct diff, idempotent second run, missing file refused, witness warning, correct unit in hints.
  Not tested against a real EFM install.

## Batch 8 — 08-tde and tools (step 2, last modules)

### 08-tde
Checked against EDB's TDE docs ("Data encryption key": key in `<datadir>/pg_encryption/key.bin`, openssl example
`-aes-128-cbc -pbkdf2`; "Rotating the data encryption key": re-wrap = `old unwrap | new wrap > key.bin.new; mv`).
- **`tde-openssl-to-thales-migrate.sh` — could not work and was unsafe if it had:**
  - looked for `DATA_TOP/global/pg_encryption/key.bin` (wrong path → always stopped at the first check);
  - unwrapped with `-aes-256-cbc` without `-pbkdf2`, but `epas-base-build.sh` wraps with `-aes-128-cbc -pbkdf2`;
  - held the binary data key in a bash variable — `$(...)` drops NUL bytes and trailing newlines (shown in the
    test: a 32-byte key came back as 28 bytes), which would have re-wrapped a corrupted key → server never starts;
  - wrote Thales output straight over the live `key.bin` (a failed wrap truncates it, while the message said "key.bin untouched");
  - rollback was manual; `edb-as-${EPAS_VERSION}` hard-coded; test file at a fixed `/tmp` path.
  Rewritten: common.sh; unwraps with the server's own `data_encryption_key_unwrap_command` (or `OLD_UNWRAP_CMD`);
  pipe old-unwrap → Thales-wrap → `key.bin.new` while the DB keeps running; SHA-256 comparison of both unwrapped keys;
  backup outside the data dir; stop → swap → conf change (old line commented, dated) → start → `data_encryption_version=1`;
  **automatic rollback** on any start/check failure; refuses if the unwrap command is also set in
  postgresql.auto.conf/conf.d; reminder to run on every standby and to keep the old wrapped key + passphrase for old backups.
- **`tde-thales-setup.sh`:** common.sh (`--env` and default `conf/tde.env`, which the old version did not have —
  it needed the file as an argument); placeholder checks for `THALES_PASS`/UUID; TDE detection via `key.bin`; clear
  routing for existing clusters (non-TDE → 04-upgrade, passphrase TDE → migrate script, KMIP → nothing to do);
  `SRC_BINARY_DIR` instead of a guessed `/usr/edb/asN`; verification is a temporary `pg_ctl` start/stop (the old
  version started `edb-as-N` before `epas-base-build.sh` had written the systemd drop-in, i.e. with the wrong
  PGDATA); documented order: this script, then `epas-base-build.sh` (skips initdb for an existing cluster);
  on a failed check it says to empty `DATA_TOP` before re-running (a re-run would otherwise report "nothing to do").
- New `thales-kmip.sh` (sourced): package install, certificate staging, `pykmip.conf` (backed up if present), round
  trip with a `mktemp` file; `runuser` so an `env:` passphrase reaches the unwrap command (sudo clears the environment).
- README rewritten (usage, order with 01, correct key path, rollback); `conf/tde.env.example`: `OLD_UNWRAP_CMD` documented.
- Tested (sandbox: KMIP client fake doing real openssl encryption keyed by the UUID; fake server whose start runs the
  configured unwrap command and must reproduce the real key; key with NUL bytes + trailing newline): migrate happy
  path (new key.bin unwraps to the identical key, server running); re-run → nothing to do; wrong old passphrase →
  key unchanged, DB running; Thales unreachable → nothing changed; start failure after swap → automatic rollback,
  key + conf restored, DB running; unwrap command in conf.d → refused; setup: non-TDE / passphrase-TDE / KMIP
  clusters routed correctly, new cluster created + verified + left stopped, Thales unreachable → no data dir created.
  Not tested against a real Thales CipherTrust Manager or real EPAS TDE.

### tools/get-edb-inventory.sh
Wrote `/etc/edb/inventory.conf` (nothing reads it; failed for non-root at `mkdir /etc/edb`, although `make inventory`
is described as listing); guessed bin dir/port from the service name; `awk $3` port parse broke on `port=5444`;
EPAS's `-D ${PGDATA}` not resolved. Rewritten as a read-only report (stdout, `--output FILE` optional): finds
postmasters in the process table (systemd or not) and reads data dir (`/proc/pid/cwd`), port (`postmaster.pid`),
binaries (`/proc/pid/exe`), version, role (standby.signal), TDE (key.bin), systemd unit (cgroup); plus EFM clusters
(properties files) and units, pgBackRest, EDB packages. Every lookup falls back to empty (found during testing:
under pipefail a failing `systemctl`/`ip` pipeline ended the report silently).
Tested with two live PostgreSQL 16 clusters (standby flag, TDE flag), as root and as a non-root user, and with
failing ip/systemctl/rpm/pgbackrest stubs.

Step 2 is now complete: every script that reads the site config uses `lib/common.sh`. Two standalone helpers in
02-ssl that take only command-line arguments and no config stay as they are: `generate-selfsigned-single.sh` and
`tests/preflight-check.sh`.
