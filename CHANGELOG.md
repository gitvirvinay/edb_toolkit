# Changelog

What changed in edb_toolkit, newest first. Updated together with every change.

## Unreleased

- **`tools/epas_full_uninstall.sh` now asks before it deletes anything.** On a terminal you type
  the host name to continue; unattended (cron, Ansible, a pipe) it refuses unless `--yes` is given.
  Before, it started deleting as soon as it was run. The run is logged in `<LOG_MOUNT>/toolkit`
  with audit lines for who confirmed it and when it finished.
- The uninstall script lists what it leaves in place (`DATA_TOP`, `WAL_TOP`, `ARCHIVE_TOP`,
  `BACKUP_TOP`, `LOG_TOP`, `BINARY_TOP`, with sizes) for removal by hand. It never deleted them,
  but did not say so.
- Its leftover-process check no longer reports unrelated programs (it matched `post`, as in postfix).
- New in `lib/common.sh`: `confirm_destructive`, for actions that cannot be undone.

## v2.0.0 - 2026-11-12

- **Breaking: the patching scripts are renamed, and four became two.** One pair of scripts now
  serves both sites, with or without EFM; `SITE` and `HA_TOOL` in `site.env` decide what they do.
  The `primary_site/` and `dr_site/` folders are gone. Update runbooks that use the old names:

  | Old name | New name (in `modules/03-patching/`) |
  |---|---|
  | `primary_site/patch-primary-shutdown.sh`, `dr_site/patch-dr-shutdown.sh` | `node-maintenance-stop.sh` |
  | `primary_site/patch-primary-startup.sh`, `dr_site/patch-dr-startup.sh` | `node-maintenance-start.sh` |
  | `epas-minor-patch-update.sh` | `epas-minor-update.sh` |
  | `efm-rolling-minor-patch.sh` | `epas-minor-update-efm.sh` |

- New setting `SITE` (`primary` or `dr`, default `primary`). `node-maintenance-stop.sh` lists the
  node's IP addresses only at the primary site. `node-maintenance-start.sh` now waits for EFM to
  report the cluster at the DR site too (before, only at the primary site).
- **Clusters without EFM can be taken out of service and brought back with the same scripts.**
  New setting `HA_TOOL` (`efm` or `none`, default `efm`). With `none`, the `node-maintenance-*`
  scripts skip the EFM steps, and `epas-minor-update-efm.sh` stops and points to
  `epas-minor-update.sh`. Safety check: with `none`, `node-maintenance-stop.sh` refuses to stop
  EPAS if an EFM agent is running on the host after all.
- **Patching safety.** A failed stop or start is no longer ignored: if EFM or EPAS cannot be
  stopped, or EPAS is still running afterwards, `node-maintenance-stop.sh` stops with an error
  and writes no audit line. EPAS is never stopped when EFM could not be stopped and disabled first.
- `epas-minor-update.sh` refuses to run while an EFM agent is active on the host and points to
  `epas-minor-update-efm.sh` (stopping EPAS under a running agent can cause a failover).
- New settings `APP_CODE` and `BACKUP_TOOL` (`basebackup`, `barman`, `pgbackrest`, `none`).
  They are checked but not used by any script yet.
- Every script that loads `site.env` now stops at the start, before changing anything, when
  one of these settings has a value outside its list.
- A config file without the new settings behaves exactly as before.
- New unit tests (`tests/common-unit.sh`, run by `make test` and CI).

## v1.1.0 - 2026-11-12

- **Toolkit logs moved out of `/var/log`.** Each script run now writes its own file in
  `<LOG_MOUNT>/toolkit` (`/pglog/toolkit`; change it with `TOOLKIT_LOG_DIR` in `site.env`).
  The logger no longer uses `sudo` and no longer makes a log file writable by everyone;
  new files are mode 640.
  **Action on each server:** root creates the directory once, owned by the database OS user:
  `install -d -o enterprisedb -g enterprisedb -m 2750 /pglog/toolkit`. Until then the scripts
  still run, print on the screen only, and say so.
- `epas-base-build-root.sh` creates that directory on a new server (mode 2750: log files
  written by a root run get the database group, so the DBA can read them). It refuses a
  path inside a system directory such as `/var/log`.
- Messages are copied to syslog only when `TOOLKIT_SYSLOG="yes"` (it was always on).
- New unit tests for the logger (`tests/logger-unit.sh`, run by `make test` and CI).
- Scripts that are run directly are now marked executable (`tools/install.sh`,
  `epas-ssl-setup.sh`, both upgrade scripts and five others), so they no longer need
  `chmod +x` on a server.

## v1.0.0 - 2026-11-11

- Starting version: modules 01-provision to 08-tde, shared `lib/`, `conf/` templates,
  unit tests and CI lint.
- Earlier history is not kept in this repository.
