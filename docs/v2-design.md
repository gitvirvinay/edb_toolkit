# edb_toolkit v2 — design

Version: 2026-11-09 · Status: agreed direction, built step by step (evolve, not rewrite)

The toolkit grows from feature folders (ssl, patching, upgrade, efm) into the build sequence
**decide → prepare → prove → build → prove recovery → run**, with the feature modules inside it.
The tested code (02-ssl, `lib/`, unit tests, CI) is kept and moved, not rewritten.

## Principles

1. **Phases are the backbone.** Each module belongs to one phase of the build sequence.
2. **Every module has `--check` before `--apply`.** A read-only check that works on new and on
   grandfathered servers and reports OK, WARN or FAIL. Most of the estate is already built, so
   `--check` is the first thing to build: it audits servers without changing them.
3. **A tier policy file decides what is required.** The DEV/SIT/PAT/PROD matrix becomes
   `conf/tier-policy.env`, read by the scripts. Example: PROD refuses to build without
   `verify-full` or a standby; DEV accepts a self-signed certificate. One place for the rules.
4. **Every step writes evidence.** Disk, CPU, pgbench, restore-test and failover-test results go to
   one folder per cluster, e.g. `<evidence dir>/<cluster>/<date>-<step>.txt` (outside PGDATA; exact
   location to be decided), with a copy in Git or on a share. The build proves itself to auditors.
5. **Root stays small.** Root does only OS work: mounts, sysctl, packages, systemd drop-ins, sudoers.
   Everything else runs as the DB user. `--plan` prints the root commands for sysadmins who
   won't run the scripts as root.
6. **Idempotent.** Running a script twice does no harm; the second run reports "already done".

## Module layout

| Phase | Module | Content | From | Status 2026-11-09 |
|---|---|---|---|---|
| Decide | `00-intake` | Turns the request form / kickoff answers into `site.env`, validated against the tier policy | Replaces `generate-site-env.sh` | Request form done (`docs/onboarding/`); generator detects existing servers |
| Prepare | `01-os-baseline` | DB user and group with a fixed UID/GID, chrony, locale, SELinux/firewall checks, sudoers | Split out of 01 | Not started |
| Prepare | `02-layout-kernel` | Mounts and ownership, huge pages, THP off, sysctl, tuned, systemd drop-in (`RequiresMountsFor`, `OOMScoreAdjust`) | New | **Mounts done** (storage folders, mount check, `RequiresMountsFor`); kernel part not started |
| Prove | `03-baseline` | fio, pg_test_fsync, CPU governor / NUMA / steal, pgbench with and without TDE on a throwaway cluster, then cleanup | New | Not started |
| Build | `04-cluster` | initdb with fixed settings (locale, checksums, redwood, TDE, `--waldir`), config template per tier, identity file | From 01 | `--waldir` and `log_directory` done; rest not started |
| Build | `05-ssl` | Current 02-ssl, kept as is | 02 | Done (v1.4.0 candidate) |
| Build | `06-security` | Roles model, pg_hba template, LDAP, profiles, audit | New | Not started |
| Build | `07-replication` | Standby build and rebuild, slots with `max_slot_wal_keep_size` | From 01 | Rebuild handles `WAL_TOP`; rest not started |
| Build | `08-ha-efm` (later `08-ha-patroni`) | EFM setup | 05 | Not started |
| Build | `09-backup` | pgBackRest setup; retention done by the tool, never by delete scripts | 06 | Not started (06 only validates today) |
| Build | `10-monitoring` | Exporter or PEM agent, alert list, log shipping | New | Not started |
| Prove | `11-recovery-tests` | Scripted restore and PITR test, switchover and failover test, timings saved as evidence | New | Not started |
| Run | `12-patching`, `13-upgrade`, `14-tde` | Current 03, 04, 08 | 03, 04, 08 | Existing |
| Run | `epastab.sh check` | Calls every module's `--check`: one-command health report per server | Extended | Not started |

## `site.env` changes

| Change | Status |
|---|---|
| Storage layout: `DATA_MOUNT`/`WAL_MOUNT`/`ARCHIVE_MOUNT`/`BACKUP_MOUNT`/`LOG_MOUNT` and derived `*_TOP` per cluster | **Done** |
| Identity: `CLUSTER_NAME=as17` (technical) plus `APP_CODE`; `conf.d/00-identity.conf` with `cluster_name = '<APP>_<ENV>_<asNN>'`, `dba.app_code`, `dba.env_tag`, `dba.cluster` | Decided |
| `ENV_TAG` with a real value, validated against the tier policy | Partly (build part B already requires it) |
| `TOPOLOGY=standalone\|standby\|ha\|ha_dr`, `DR_HOST`, `BACKUP_HOST` | Planned |
| `INITDB_LOCALE`, `INITDB_ENCODING`, `COLLATION_PROVIDER`, `DATA_CHECKSUMS`, `REDWOOD_COMPAT` | Planned |
| `TDE_ENABLED=yes` by default (all tiers), `HUGE_PAGES=on` (all tiers) | Decided |
| `DB_FLAVOR=epas\|pg` — only if community PostgreSQL is really coming | Open question |
| Secrets never in `site.env` — a rule the scripts check | Planned (TDE passphrase already enforced) |

## Other decisions (2026-11-09)

- **Install location (done 2026-11-09):** `/opt/dba/edb_toolkit` (with `.prev` for rollback); other DBA tools beside it.
  `install.sh` moves an old `/opt/edb_toolkit` aside, carries its `conf/*.env` over and leaves a compatibility link.
  Config and secrets stay in `/etc/edb` (`ssl`, `tde`, `toolkit/epastab`). Not `/opt/edb` (looks vendor-owned).
- **Toolkit logs:** `/pglog/toolkit/`, one file per run, directory created once by root; keep the syslog copy.
- **Huge pages, THP off, kernel tuning:** required in every tier, DEV included.
- **Tier checklist:** one master list with a column per tier; PAT mirrors PROD; same `initdb` settings everywhere.
- **HA:** Gold = primary + local standby (VIP, same subnet) + DR standby at a second site (`promotable=false`,
  promoted by a person via DNS or multi-host connection strings). Silver = 2 nodes + witness.

## Parked items a restructure fixes

- Binaries owned by root, not by `SYSTEM_USER`.
- ~~`lib/logger.sh`: no world-writable log file (`chmod 666`) and no `sudo` from every script.~~ Done: one file per run in `<LOG_MOUNT>/toolkit`, no sudo, syslog optional. Still open: the root build creates that directory.
- One TDE pass file per cluster (fixes the single unwrap command in 04-upgrade).
- Tighter sudoers for pgbackrest: specific commands, not any arguments as root.
- `epastab.sh` on the PATH; `tools/pg_bashrc.txt` renamed and linted.
- Old `generate-env.sh` references removed (template and 01-provision README done; main README left).
- Plaintext TDE passphrase in old clusters' `postgresql.conf`: `14-tde --check` finds it, a migration fixes it.

## Build order

1. Test the current toolkit on one real non-prod EPAS server (with the five mounts), then tag v1.4.0.
2. `--check` modes first (storage, huge pages/THP, SSL, TDE passphrase), wired into `epastab.sh check`.
3. `02-layout-kernel` kernel part (huge pages, THP, sysctl, `OOMScoreAdjust`) and `03-baseline`.
4. `11-recovery-tests`.
5. The rest, one module per release; renumber folders once the new modules exist.
