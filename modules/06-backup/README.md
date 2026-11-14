# 06-backup — backups for every `BACKUP_TOOL`

Which scripts act depends on `BACKUP_TOOL` in `conf/site.env` (`basebackup` | `barman` | `pgbackrest` | `none`).
Each script checks it and does nothing (or refuses) when it is not the right one.

## `BACKUP_TOOL=basebackup`

| Script | Run as | Purpose |
|---|---|---|
| `enable-wal-archiving.sh [--env conf/site.env]` | `SYSTEM_USER` | Stages `conf.d/06-archiving.conf` (`archive_mode=on`, `archive_command` → `archive-wal.sh`). Never overwrites an existing file. Called automatically by `epas-base-build-db.sh` for a new cluster (before first start — no restart needed); safe to also run by hand against an existing cluster, where it warns that `archive_mode` needs a **restart** (use `03-patching/node-maintenance-stop.sh` / `node-maintenance-start.sh`). |
| `archive-wal.sh` | (called by EPAS, not by hand) | The `archive_command` itself: copies each WAL file into `ARCHIVE_TOP`, refusing to overwrite a file already there with different content (the classic archiving mistake), and writes under a temp name + `mv` so a crash never leaves a short file under the real name. |
| `take-basebackup.sh [--env conf/site.env] [--yes] [tag]` | `SYSTEM_USER` | Checks EPAS is up and `BACKUP_TOP` has enough free space, then `pg_basebackup`s into `BACKUP_TOP/<timestamp>_<tag>`. On success, prunes backups older than `BACKUP_RETENTION_DAYS` (default 10) — only after the new one succeeds, and only with `--yes` (needed for cron; a destructive step, same rule as everywhere else in this toolkit). |
| `restore-test.sh [--env conf/site.env] [--pick latest\|random] [--check-only] [--remove-kept]` | `SYSTEM_USER` | Proves a base backup restores: copies it, replays **all** archived WAL on a small temporary instance, and checks the instance is out of recovery and can write. See "Restore test" below. |

### Restore test (`restore-test.sh`)

A backup that has never been restored is a hope, not a backup. This script restores one backup
into a throw-away copy and proves that the base backup **and** the WAL archive work together.

```bash
# as enterprisedb
modules/06-backup/restore-test.sh                 # the latest backup
modules/06-backup/restore-test.sh --pick random   # any backup on disk: deeper, replays more WAL
modules/06-backup/restore-test.sh --check-only    # the safety checks only, restores nothing
modules/06-backup/restore-test.sh --remove-kept   # delete failed copies once you have looked at them
```

Runs as `SYSTEM_USER`, needs no root. Exit code `0` = pass, `1` = fail.

**What it does, in order**

1. **Chooses a backup.** Only complete backups count (both `backup_label` and `backup_manifest` present). `latest` is what
   you would use in a disaster and is quick; `random` also exercises older backups and the WAL between them.
2. **Checks before it copies anything:** settings valid; enough free space on `RESTORE_TOP` (backup size + 20%); the backup
   has no tablespaces (a restored copy would write to the live database's paths); the **TDE passphrase file** exists and is
   readable (its contents are never read, printed or logged); `pg_verifybackup` finds the backup intact.
3. **Restores.** Copies the backup under `RESTORE_TOP` at low CPU and disk priority, sets no recovery target (so *every*
   archived WAL file is replayed) and starts a temporary instance on `RESTORE_TEST_PORT`.
4. **Waits** until recovery finishes, up to `RESTORE_TEST_TIMEOUT_HOURS` (default 4), then checks the instance is no longer
   in recovery and can write.
5. **Leaves evidence and cleans up.** A pass deletes the copy; a failure keeps it for you to investigate.

**What keeps it safe.** The temporary instance runs with settings on the command line that beat every file in the copy:
its own port, `localhost` only, its own socket folder, `archive_mode=off` (it can never write into the real WAL archive),
`hot_standby=off`, small memory, no replication, no logging outside the copy. `fsync=off` and `autovacuum=off` are used
**only** because the copy is thrown away - never copy those onto a real database. The real database, the real archive and the
backups are only read.

**Evidence.** Every run except `--check-only` writes one small text file:
`<log directory>/restore-tests/<date>_<cluster>_PASS.txt` (or `_FAIL.txt`; override the folder with `RESTORE_EVIDENCE_DIR`).
It records the backup used, how it was picked, the number of WAL files replayed, TDE yes/no, duration, the reason for a
failure and what happened to the copy. This is your answer to "when did we last prove a restore works?". Old evidence files
are not removed by the toolkit.

**A failed copy blocks the next test** (`RESTORE_TEST_KEEP_MAX`, default 1), so failures cannot fill the disk. Read the
instance log inside the kept copy (`restore-test.log`), fix the cause, then run `--remove-kept`.

**What it does not prove.** The test runs on the same server as the database, so it finds the TDE passphrase file there. It
does **not** prove you could restore on a *different* server after losing this one: for that, the passphrase needs its own
protected copy outside the server (vault or escrow). A standalone database has exactly one copy of that file. Also: the
15 TB database needs a different method (Barman), and a restore needs disk space and I/O - run it outside business hours.

**Settings** (all optional, in `conf/site.env`): `RESTORE_TEST_TIMEOUT_HOURS` (4), `RESTORE_TEST_PORT` (55432),
`RESTORE_TEST_KEEP_MAX` (1), `RESTORE_TOP` (`BACKUP_TOP/restore-test`), `RESTORE_EVIDENCE_DIR`.

**Not yet proven on a real server.** Written and unit-tested with fake PostgreSQL programs only. Before relying on it, run it
once by hand on a DEV server and check three things against EPAS: that `pg_verifybackup` works on a TDE backup with
`--no-parse-wal`, that the temporary instance starts and unwraps the key, and that `grep unwrap postgresql.conf` shows the
parameter `data_encryption_key_unwrap_command` as the script expects. While it runs, a toolkit instance list may show the
temporary instance as an unregistered running cluster; that is expected and ends with the test.

## `BACKUP_TOOL=pgbackrest`

| Script | Purpose |
|---|---|
| `pgbackrest-validate.sh [--env conf/site.env]` | Stanza check, repo info, latest backup, backup verify, WAL archive continuity. Read-only. |
| `take-prepatch-snapshot.sh [--env conf/site.env]` | Checks the EPAS service is up, validates the stanza, takes a tagged backup and lists it — run before patching. |

Settings: `STANZA` (in `conf/site.env`, default `main`); optional environment overrides `BACKUP_TYPE` (default `full`) and `SNAPSHOT_TAG`. The EPAS service name comes from `EPAS_VERSION`.

## `BACKUP_TOOL=barman` / `none`

Not built yet (`barman`); nothing to do (`none`).
