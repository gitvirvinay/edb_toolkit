# Changelog

What changed in edb_toolkit, newest first. Updated together with every change.

## v3.2.0 - 2026-11-14

**Patching scripts are ready for unattended use (Ansible, cron).** See `docs/ansible-readiness.md` for the contract and for
which scripts still are not.

- `node-maintenance-start.sh` now **exits 2** when EPAS is running but EFM did not report the cluster within the wait
  (before: a warning and exit 0, so a playbook would have gone on to patch the next node). `EFM_WAIT_TRIES` and
  `EFM_WAIT_SECS` (default 12 x 5 s) set the wait.
- Both patching scripts call `sudo -n`: a missing sudoers entry fails at once instead of waiting for a password.
- `node-maintenance-stop.sh` run a second time on an already stopped node (a retry after the sysadmin's `dnf`) keeps the first
  note of the package version, so `node-maintenance-start.sh --patched` still sees the update.
- Usage text and headers of both scripts list the exit codes. 14 new checks in `tests/common-unit.sh`.

| Before | Now |
|---|---|
| `node-maintenance-start.sh`, EFM not confirmed: exit 0 | exit 2 |
| plain `sudo systemctl ...` | `sudo -n systemctl ...` |

## v3.1.0 - 2026-11-13

**New: paste kit for servers where only text can be copied.** `tools/make-paste-kit.sh` (or `make paste-kit`) builds
`dist/paste-kit-<version>/` from the committed repo: the same content as the bundle, cut into plain-text parts of about 38 KB
(`part-01.sh` ... `part-NN.sh`), plus `finish.sh` and `README.txt`. Paste each part into a terminal on the server; each one writes
its slice and checks it with sha256 (`part 3 of 8: OK`, or `DAMAGED - paste this part again`). `finish.sh` checks that every part is
present and that the whole archive is intact, then unpacks to `~/edb_kit/edb_toolkit`. It refuses to overwrite an existing copy.
Parts are plain ASCII (no tabs, no CR, short lines), so terminals and editors do not change them.

- `--lines N` changes the part size (default 500 base64 lines).
- New test `tests/paste-kit-unit.sh` (26 checks: round trip equals the committed tree, damaged and CRLF pastes caught, missing or stray part caught), in `make test` and CI.
- The Beginner's Guide has a new "Road C" for the paste kit.
- Nothing changes for existing scripts or runbooks.

## v3.0.0 - 2026-11-13

**Breaking: root and DBA are split.** The sysadmin does the root work (dnf, files in `/etc`, mounts, kernel, sudoers); the DBA runs everything
else as `enterprisedb` through the sudo whitelist, with no `su` and no `sudo -u` inside any script (the TDE/Thales scripts are the one
exception until the POC settles). See `docs/who-runs-what.md`. What to change in your runbooks:

| Before | Now |
|---|---|
| `sudo epas-minor-update.sh` / `sudo epas-minor-update-efm.sh` | DBA `node-maintenance-stop.sh` -> sysadmin `dnf upgrade -y 'edb-as<ver>*'` -> DBA `node-maintenance-start.sh --patched` |
| `epas-major-pgupgrade.sh --root`, `epas-major-pgrestore.sh --root` | run as `enterprisedb`; the sysadmin installs the new packages first |
| `sudo efm-setup.sh [--no-install] [--start]` | DBA `efm-setup.sh` prepares the files; sysadmin runs the printed `dnf` and `install` commands; DBA starts the agent with `sudo systemctl` |
| `sudo efm-reconfigure-after-upgrade.sh` | DBA `efm-reconfigure-after-upgrade.sh` prepares the file; sysadmin runs the printed `install`; DBA runs it again to confirm |
| `sudo epas-base-build.sh` (wrapper) | `epas-base-build-root.sh` (sysadmin), then `epas-base-build-db.sh` (DBA) |
| sudoers: EPAS 15-17 | `conf/sudoers.d/epas-automation` now also lists EPAS 18; the sysadmin re-installs it once per server |

Also in this release (since v2.0.0): the backup module, the restore test, the EPAS 17 upgrade (Track A) and the EFM guard in the upgrade script.

- **Breaking: root and DBA split in patching. `epas-minor-update.sh` and `epas-minor-update-efm.sh` are removed.**
  They ran as root and called `dnf` in the middle of a run. The sysadmin now runs `dnf`; the DBA runs only
  `node-maintenance-stop.sh` and `node-maintenance-start.sh --patched`, using the sudo whitelist
  (`conf/sudoers.d/epas-automation`) and no root of their own. Steps: stop (DBA) -> `dnf upgrade -y 'edb-as<ver>*'` (sysadmin) -> start `--patched` (DBA).
  | Removed | Use instead |
  |---|---|
  | `epas-minor-update.sh`, `epas-minor-update-efm.sh` | `node-maintenance-stop.sh`, sysadmin `dnf`, `node-maintenance-start.sh --patched` |
  - `node-maintenance-stop.sh` notes the installed package version once EPAS is stopped.
  - `node-maintenance-start.sh --patched` checks that the version changed (starts nothing if not), runs
    `edb_sqlpatch` as the DBA on a primary only (not on a standby), and only then starts EFM. Without `--patched`, behaviour is unchanged.
  - The VIP check is information only now (and silent when `VIP_ADDRESS` is empty); the old "continue despite missing VIP?" question is gone.
  - `lib/common.sh`: new `run_as_db_user` (runs directly when already the DB user, no `sudo -u`); `wait_for_epas` uses it; new `epas_cmd`.
  - **Breaking: `epas-major-pgupgrade.sh` and `epas-major-pgrestore.sh` no longer have `--root`.** They run as the database OS user only
    (they already did by default); the sysadmin installs the EPAS packages beforehand. `--root` now stops with a message saying so.
  - **`efm-reconfigure-after-upgrade.sh` no longer runs as root and no longer edits `/etc`.** The DBA runs it: it reads the properties
    file, builds the corrected copy in `<log directory>/efm/` (mode 600) and prints the two commands for the sysadmin (backup, then
    `install -o <owner> -g <group> -m <mode>`). Running it again says "already up to date" once the sysadmin has done that.
    New `tests/efm-reconfigure-unit.sh` (27 tests), added to `make test` and CI.
  - **Breaking: `efm-setup.sh` no longer runs as root, installs nothing and has no `--no-install` / `--start`.** The DBA runs it: it builds the
    properties, nodes and (for a cluster not named `efm`) unit file in `<log directory>/efm/<cluster>/`, compares them with the installed
    files and prints the root commands for the sysadmin (`dnf install`, backup, `install -o efm -g efm -m 600 ...`, `daemon-reload`).
    Running it again says "already installed". The DBA starts the agent with `sudo systemctl enable/start <unit>` (whitelist).
    New `tests/efm-setup-unit.sh` (44 tests), added to `make test` and CI.
  - **Removed: the `epas-base-build.sh` wrapper and `conf/sudoers.d/deployer.sample`.** The wrapper made root run the DBA's part through
    `sudo -u`, which the sysadmins do not want; the sample whitelist was unsafe (its own header said so). Use `epas-base-build-root.sh`
    (sysadmin, root) and then `epas-base-build-db.sh` (DBA, as `enterprisedb`).
  - New `docs/who-runs-what.md`: which steps the sysadmin (root) runs and which the DBA runs, per task. The two TDE/Thales scripts remain the documented exception until the POC settles.
  - `conf/sudoers.d/epas-automation`: EPAS 18 added (start, stop, restart, reload).

- **New: `modules/06-backup/restore-test.sh` - proves a base backup really restores.** It picks the
  latest backup (or `--pick random`), checks free space, tablespaces, the TDE passphrase file and
  `pg_verifybackup`, copies the backup, replays **all** archived WAL on a small temporary instance
  (its own port, `archive_mode=off` so it can never write into the real archive) and checks the
  instance is out of recovery and can write. A pass deletes the copy; a failure keeps it, and no new
  test starts until it is cleared with `--remove-kept`. Every run leaves an evidence file in
  `<log directory>/restore-tests/`. Never reads, prints or copies the TDE passphrase.
  New optional settings: `RESTORE_TEST_TIMEOUT_HOURS`, `RESTORE_TEST_PORT`, `RESTORE_TEST_KEEP_MAX`,
  `RESTORE_TOP`, `RESTORE_EVIDENCE_DIR`. Not yet run against a real EPAS server.
- CI now also runs `tests/backup-unit.sh` (it was only run by `make test`) and the new
  `tests/restore-test-unit.sh`.

- **New backup module for `BACKUP_TOOL=basebackup`** (`modules/06-backup/`):
  - `enable-wal-archiving.sh` stages `conf.d/06-archiving.conf` (`archive_mode=on`, `archive_command`
    → `ARCHIVE_TOP`). Called automatically from `epas-base-build-db.sh` for a new cluster; also safe
    to run against an existing one, where it warns that `archive_mode` needs a restart.
  - `archive-wal.sh`, the `archive_command` itself: never overwrites a differing WAL file already at
    the destination, and writes under a temp name before `mv`, so a crash never leaves a short file
    under the real name.
  - `take-basebackup.sh` takes a `pg_basebackup` into `BACKUP_TOP/<timestamp>_<tag>` (checking free
    space first) and, only after it succeeds, prunes backups older than the new setting
    `BACKUP_RETENTION_DAYS` (default 10) — pruning needs `--yes` (for cron), same rule as every other
    destructive action in this toolkit.
  - These act only when `BACKUP_TOOL=basebackup`; every other value is a no-op or a clear refusal that
    points at the right tool (pgBackRest manages its own `archive_command`; Barman is not built yet).
  - New unit tests (`tests/backup-unit.sh`, run by `make test` and CI).

- `generate-selfsigned-single.sh` now logs through `lib/common.sh` like every other script
  (a run is recorded in `<LOG_MOUNT>/toolkit`, and it accepts `--env`/`--help` the same way).
  No behavior change otherwise: same arguments, same output bundle.
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
