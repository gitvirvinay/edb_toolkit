# 01-provision — Day-1 build & standby rebuild

All scripts accept `--env conf/site.env`, `--env=conf/site.env` or the file as first argument; with nothing
given they use `conf/site.env` in the repo (required). Each run prints its settings and asks
**"Proceed? (y/N)"** on a terminal (`--yes` skips it).

| Script | Run as | Purpose |
|---|---|---|
| `generate-env.sh [--force] [output]` | root | Detects EPAS version, data dir, OS user, port and asks you to confirm each; writes `conf/site.env` (default) built from `conf/site.env.example`. Never overwrites silently — asks, or `--force` keeps the old file as `.bak_<timestamp>`. |
| `epas-base-build.sh` | root / sudo-whitelisted user | **The Day-1 build.** Installs EPAS packages, moves the binaries to `BINARY_TOP` and leaves `SRC_BINARY_DIR` as a compatibility symlink, ownership, systemd drop-in, `initdb` with TDE (`--data-encryption=256`), and numbered `conf.d` templates (port from `PRIMARY_PORT`, memory sized to the host) that are never overwritten on re-run. Stops if the TDE passphrase is still the `CHANGEME` placeholder or if `BINARY_TOP` = `SRC_BINARY_DIR`. |
| `epas-prep-primary.sh` | `SYSTEM_USER` (e.g. `sudo su - enterprisedb`) | Creates `REP_USER` with a random password (saved in this user's `~/.pgpass`), adds replication rules for `SUBNET_CIDR` to `pg_hba.conf`, reloads EPAS. **Copy the `.pgpass` line to the standby** (the script reminds you). |
| `epas-rebuild-standby.sh` | `SYSTEM_USER` on the standby | Stops local EPAS, moves `DATA_TOP` aside to `DATA_TOP_bak_<timestamp>`, re-clones from the primary with `pg_basebackup` (optional slot), starts it. **Refuses to run on a running primary.** If the copy fails, only the partial new copy is removed; the previous data stays in the `_bak` directory. |

See `../../docs/dnf-install-recommendation.md` for the recommended package install command.
