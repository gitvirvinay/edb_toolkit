# 01-provision — Day-1 build & standby rebuild

All scripts accept `--env conf/site.env`, `--env=conf/site.env` or the file as first argument; with nothing
given they use `conf/site.env` in the repo (required). Each run prints its settings and asks
**"Proceed? (y/N)"** on a terminal (`--yes` skips it).

| Script | Run as | Purpose |
|---|---|---|
| `generate-env.sh [--force] [output]` | root | Detects EPAS version, data dir, OS user, port and asks you to confirm each; writes `conf/site.env` (default) built from `conf/site.env.example`. Never overwrites silently — asks, or `--force` keeps the old file as `.bak_<timestamp>`. |
| `epas-base-build-root.sh` | root (`sudo`, or Ansible `become: true`) | **Day-1 build, part A.** Installs EPAS packages, moves the binaries to `BINARY_TOP` and leaves `SRC_BINARY_DIR` as a compatibility symlink, creates `DATA_TOP`, ownership, systemd drop-in, registry directory `/etc/edb/toolkit` (`epastab.sh init`) and the TDE passphrase directory `TDE_PASS_DIR` (`/etc/edb/tde`, owned by `SYSTEM_USER`, mode 0700). Calls no `sudo` itself. Stops if `BINARY_TOP` = `SRC_BINARY_DIR`. |
| `epas-base-build-db.sh [--tag TAG]` | `SYSTEM_USER` (e.g. `sudo -iu enterprisedb`) | **Day-1 build, part B, no root.** Writes the TDE passphrase file `/etc/edb/tde/<CLUSTER_NAME>.pass` (mode 0400; from an existing file, `$TDE_PASSPHRASE`, or a hidden prompt asked twice), tests wrap/unwrap, `initdb` with TDE (`--data-encryption=256`; skipped when `DATA_TOP` is already a cluster), numbered `conf.d` templates (port from `PRIMARY_PORT`, memory sized to the host; never overwritten on re-run), and registers the cluster (`epastab.sh add`, which also rewrites `pg_service.conf`). Tag from `--tag` or `ENV_TAG`, never guessed. All checks run before any change; it refuses the old `-pass pass:` TDE commands, which would put the passphrase in plain text in `postgresql.conf`. |
| `epas-base-build.sh` | root | Compatibility wrapper (to be removed): runs part A, then part B as `SYSTEM_USER` (passes `--env`, `--yes`, `--tag`, `$TDE_PASSPHRASE`). |
| `epas-prep-primary.sh` | `SYSTEM_USER` (e.g. `sudo su - enterprisedb`) | Creates `REP_USER` with a random password (saved in this user's `~/.pgpass`), adds replication rules for `SUBNET_CIDR` to `pg_hba.conf`, reloads EPAS. **Copy the `.pgpass` line to the standby** (the script reminds you). |
| `epas-rebuild-standby.sh` | `SYSTEM_USER` on the standby | Stops local EPAS, moves `DATA_TOP` aside to `DATA_TOP_bak_<timestamp>`, re-clones from the primary with `pg_basebackup` (optional slot), starts it. **Refuses to run on a running primary.** If the copy fails, only the partial new copy is removed; the previous data stays in the `_bak` directory. |

Day-1 build, step by step:

```bash
sudo modules/01-provision/epas-base-build-root.sh --env conf/site.env             # sysadmin, once per host
sudo -iu enterprisedb /opt/edb_toolkit/modules/01-provision/epas-base-build-db.sh --tag SIT   # DBA
sudo systemctl start edb-as-17
```

Pro tip: keep the TDE passphrase in your vault as well. The file on the host is what lets the server start
unattended; the vault copy is what lets you restore a backup on a new host.

See `../../docs/dnf-install-recommendation.md` for the recommended package install command.
