# 01-provision — Day-1 build & standby rebuild

All scripts accept `--env conf/site.env`, `--env=conf/site.env` or the file as first argument; with nothing
given they use `conf/site.env` in the repo (required). Each run prints its settings and asks
**"Proceed? (y/N)"** on a terminal (`--yes` skips it).

| Script | Run as | Purpose |
|---|---|---|
| `generate-site-env.sh [--instance V\|DIR] [--force] [output]` | root | Detects EPAS version, data dir, OS user, port and the storage folders (an existing cluster's real `pg_wal` and `log_directory`; for a new build `/pgwal`, `/pgarchive`, `/pgbackup`, `/pglog` when those mounts exist) and asks you to confirm each; writes `conf/site.env` (default) built from `conf/site.env.example`. Works on new and on already-built servers. Never overwrites silently — asks, or `--force` keeps the old file as `.bak_<timestamp>`. |
| `epas-base-build-root.sh` | root (`sudo`, or Ansible `become: true`) | **Day-1 build, part A.** Installs EPAS packages, moves the binaries to `BINARY_TOP` and leaves `SRC_BINARY_DIR` as a compatibility symlink, creates the storage folders `DATA_TOP`, `WAL_TOP`, `ARCHIVE_TOP`, `BACKUP_TOP`, `LOG_TOP` (owned by `SYSTEM_USER`, mode 0700; their parent mount goes to `SYSTEM_USER` with mode 0750) and checks they are on separate filesystems (warning only), systemd drop-in (with `RequiresMountsFor=` the data, WAL and log folders), registry directory `/etc/edb/toolkit` (`epastab.sh init`) the TDE passphrase directory `TDE_PASS_DIR` (`/etc/edb/tde`, owned by `SYSTEM_USER`, mode 0700) and the toolkit log directory `TOOLKIT_LOG_DIR` (`<LOG_MOUNT>/toolkit`, owned by `SYSTEM_USER`, mode 2750: files created there, also by root, get the database group). Calls no `sudo` itself. Stops if `BINARY_TOP` = `SRC_BINARY_DIR`. |
| `epas-base-build-db.sh [--tag TAG]` | `SYSTEM_USER` (the database OS user) | **Day-1 build, part B, no root.** Writes the TDE passphrase file `/etc/edb/tde/<CLUSTER_NAME>.pass` (mode 0400; from an existing file, `$TDE_PASSPHRASE`, or a hidden prompt asked twice), tests wrap/unwrap, `initdb` with TDE (`--data-encryption=256`), WAL in `WAL_TOP` (`--waldir`) when set, and `pg_hba.conf` set to `peer` locally and `scram-sha-256` over TCP, never `trust` (skipped when `DATA_TOP` is already a cluster), numbered `conf.d` templates (port from `PRIMARY_PORT`, memory sized to the host, `log_directory` = `LOG_TOP` when set; never overwritten on re-run), enables WAL archiving when `BACKUP_TOOL=basebackup` (`../06-backup/enable-wal-archiving.sh`), and registers the cluster (`epastab.sh add`, which also rewrites `pg_service.conf`). Tag from `--tag` or `ENV_TAG`, never guessed. All checks run before any change; it refuses the old `-pass pass:` TDE commands, which would put the passphrase in plain text in `postgresql.conf`. |
| `epas-prep-primary.sh` | `SYSTEM_USER` (the database OS user) | Creates `REP_USER` with a random password (saved in this user's `~/.pgpass`), adds replication rules for `SUBNET_CIDR` to `pg_hba.conf`, reloads EPAS. **Copy the `.pgpass` line to the standby** (the script reminds you). |
| `epas-rebuild-standby.sh` | `SYSTEM_USER` on the standby | Stops local EPAS, moves `DATA_TOP` (and `WAL_TOP` when set) aside to `<folder>_bak_<timestamp>`, re-clones from the primary with `pg_basebackup` (`--waldir=WAL_TOP` when set, optional slot), checks SSL, starts it. **Refuses to run on a running primary.** Before stopping anything it checks that the binaries match the primary's major version, that there is room for a full new copy beside the old directory, and (with TDE) that the passphrase file named by `TDE_UNWRAP_CMD` exists on this host; the copied `postgresql.conf` is checked again before starting. It uses `--checkpoint=fast`. SSL: the primary's `conf.d/ssl.conf` comes along; if the files it names are missing on this host it stops before starting (data kept) and tells you to run `02-ssl/epas-ssl-setup.sh`; a certificate that does not fit this host, or SSL files inside the data directory (copied from the primary), only warn. If the copy fails, only the partial new copy is removed; the previous data stays in the `_bak` directory. |

## Storage layout (`conf/site.env`)

One mount per kind of file, each its own filesystem, and one folder per cluster under each mount
(`<mount>/<CLUSTER_NAME>`, derived in the template - never the mount root):

| Mount (`site.env`) | Folder | Holds | Empty means |
|---|---|---|---|
| `DATA_MOUNT=/pgdata` | `DATA_TOP` | PGDATA | (required) |
| `WAL_MOUNT=/pgwal` | `WAL_TOP` | `pg_wal` (`initdb` / `pg_basebackup --waldir`) | `pg_wal` inside PGDATA (old layout) |
| `ARCHIVE_MOUNT=/pgarchive` | `ARCHIVE_TOP` | archived WAL for PITR, or the pgBackRest async spool | not used |
| `BACKUP_MOUNT=/pgbackup` | `BACKUP_TOP` | local base backups (other storage than `/pgdata`; copy them on to a backup server) | not used |
| `LOG_MOUNT=/pglog` | `LOG_TOP` | server logs (`log_directory`) | `log` inside PGDATA (old layout) |

Existing `/u001` servers: `DATA_MOUNT="/u001/data"` (or set any `*_TOP` to a full path). Both build parts
print a storage check: OK per folder, or WARN when a folder is on `/` or shares a filesystem with `DATA_TOP`
(or the archive with WAL). It is a warning, so a lab build still works; for PAT/PROD get the mounts first.
`ARCHIVE_TOP` and `BACKUP_TOP` are only created here - the backup setup that uses them comes later.

Day-1 build, step by step:

```bash
sudo modules/01-provision/epas-base-build-root.sh --env conf/site.env             # sysadmin, once per host
/opt/dba/edb_toolkit/modules/01-provision/epas-base-build-db.sh --tag SIT   # DBA, as enterprisedb
sudo systemctl start edb-as-17
```

Pro tip: keep the TDE passphrase in your vault as well. The file on the host is what lets the server start
unattended; the vault copy is what lets you restore a backup on a new host.

See `../../docs/dnf-install-recommendation.md` for the recommended package install command.
