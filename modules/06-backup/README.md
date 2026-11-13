# 06-backup — backups for every `BACKUP_TOOL`

Which scripts act depends on `BACKUP_TOOL` in `conf/site.env` (`basebackup` | `barman` | `pgbackrest` | `none`).
Each script checks it and does nothing (or refuses) when it is not the right one.

## `BACKUP_TOOL=basebackup`

| Script | Run as | Purpose |
|---|---|---|
| `enable-wal-archiving.sh [--env conf/site.env]` | `SYSTEM_USER` | Stages `conf.d/06-archiving.conf` (`archive_mode=on`, `archive_command` → `archive-wal.sh`). Never overwrites an existing file. Called automatically by `epas-base-build-db.sh` for a new cluster (before first start — no restart needed); safe to also run by hand against an existing cluster, where it warns that `archive_mode` needs a **restart** (use `03-patching/node-maintenance-stop.sh` / `node-maintenance-start.sh`). |
| `archive-wal.sh` | (called by EPAS, not by hand) | The `archive_command` itself: copies each WAL file into `ARCHIVE_TOP`, refusing to overwrite a file already there with different content (the classic archiving mistake), and writes under a temp name + `mv` so a crash never leaves a short file under the real name. |
| `take-basebackup.sh [--env conf/site.env] [--yes] [tag]` | `SYSTEM_USER` | Checks EPAS is up and `BACKUP_TOP` has enough free space, then `pg_basebackup`s into `BACKUP_TOP/<timestamp>_<tag>`. On success, prunes backups older than `BACKUP_RETENTION_DAYS` (default 10) — only after the new one succeeds, and only with `--yes` (needed for cron; a destructive step, same rule as everywhere else in this toolkit). |

## `BACKUP_TOOL=pgbackrest`

| Script | Purpose |
|---|---|
| `pgbackrest-validate.sh [--env conf/site.env]` | Stanza check, repo info, latest backup, backup verify, WAL archive continuity. Read-only. |
| `take-prepatch-snapshot.sh [--env conf/site.env]` | Checks the EPAS service is up, validates the stanza, takes a tagged backup and lists it — run before patching. |

Settings: `STANZA` (in `conf/site.env`, default `main`); optional environment overrides `BACKUP_TYPE` (default `full`) and `SNAPSHOT_TAG`. The EPAS service name comes from `EPAS_VERSION`.

## `BACKUP_TOOL=barman` / `none`

Not built yet (`barman`); nothing to do (`none`).
