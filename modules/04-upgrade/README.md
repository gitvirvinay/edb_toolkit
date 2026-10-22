# 04-upgrade — EPAS major version upgrades

Settings come from `conf/site.env` (required): the **new** cluster (`EPAS_VERSION`, `DATA_TOP`, `SRC_BINARY_DIR`,
`SERVICE_NAME`, `SYSTEM_USER`, `PRIMARY_PORT`) and the **old** cluster (`OLD_EPAS_VERSION`, `OLD_DATA_TOP`,
`OLD_SRC_BINARY_DIR`, `OLD_SERVICE_NAME`, `OLD_PORT`).

## `epas-major-pgupgrade.sh` — pg_upgrade (recommended path)

```bash
# as the EPAS OS user
modules/04-upgrade/epas-major-pgupgrade.sh            # copy mode (needs free space ≈ old cluster + 10 %)
modules/04-upgrade/epas-major-pgupgrade.sh --link     # hard-link mode (not allowed with TDE)
# or as root (pg_upgrade then runs via sudo -u SYSTEM_USER)
sudo modules/04-upgrade/epas-major-pgupgrade.sh --root
```

Steps: checks (versions, binaries, both clusters exist; the new one must already be built with
`01-provision/epas-base-build.sh`) → settings summary → disk-space check (copy mode) → "verified backup taken?" →
TDE key commands (from `TDE_WRAP_CMD`/`TDE_UNWRAP_CMD`, or asks for the passphrase) → `pg_upgrade --check` →
confirmation → stop both services → `pg_upgrade` → start the new service → rebuild statistics
(`vacuumdb --all --analyze-in-stages`; pg_upgrade 14+ no longer writes `analyze_new_cluster.sh`).

If `pg_upgrade` fails after the services were stopped, the new service is **not** started and the script tells you
how to bring the old cluster back (copy mode: the old cluster is untouched).

TDE: a cluster is treated as encrypted when `<datadir>/pg_encryption/key.bin` exists. If either cluster is
encrypted, the script adds **`--copy-by-block`** automatically: the new cluster built by `epas-base-build.sh` has its
own data key, so pg_upgrade decrypts each block with the old key and re-encrypts it with the new one (slower than a
plain copy; plan the maintenance window accordingly). `--link` is refused for encrypted clusters.
Both clusters' keys are unwrapped with the same `PGDATAKEYUNWRAPCMD` (from `TDE_UNWRAP_CMD` or the passphrase you
type), so both must have been wrapped with the same passphrase/command. See the EDB docs on [pg_upgrade TDE options](https://www.enterprisedb.com/docs/tde/latest/pg_upgrade_arguments/).

## `epas-major-pgrestore.sh` — logical dump/restore

Use when `pg_upgrade` isn't an option: moving to a new server or OS, changing encoding/locale or TDE settings, or
cleaning out bloat. Slower than `pg_upgrade` for large databases. Both clusters run side by side: old on `OLD_PORT`,
new on `PRIMARY_PORT`. The new cluster must already be built with `01-provision/epas-base-build.sh` (that script
does initdb, TDE and conf.d; this one only copies data). **The old cluster is only read, never changed.**

```bash
# as the EPAS OS user
modules/04-upgrade/epas-major-pgrestore.sh                    # every database that allows connections
modules/04-upgrade/epas-major-pgrestore.sh --db sales --db hr # only these
modules/04-upgrade/epas-major-pgrestore.sh --jobs 8 --dump-dir /backup/upg   # more parallelism, dumps elsewhere
# or as root (tools run via sudo -u SYSTEM_USER)
sudo modules/04-upgrade/epas-major-pgrestore.sh --root
```

Steps: checks (versions actually running on both ports, new cluster built, dump dir not in /tmp or a data dir) →
starts either cluster if it's down (asks first) → refuses if the new cluster already holds these databases (or
user tables in `postgres`/`edb`) → every extension used on the old cluster must be installable on the new one
(and `pg_cron`/`pgaudit` must be in `shared_preload_libraries`) → disk space for dumps + restored data →
warns about other sessions on the old cluster → confirmation → **roles & tablespaces** (`pg_dumpall --globals-only`,
including password hashes) → **each database**: `pg_dump -Fd -j N` then `pg_restore -j N` (new databases with
`--create`, so owner/encoding/locale/settings/ACLs/comment come across; for `postgres`/`edb`, which initdb already
created, the database-level settings are copied separately) → `vacuumdb --analyze-in-stages` → compares counts of
user tables/views/sequences and functions, old vs new.

The new version's `pg_dump`/`pg_restore` are used for both clusters (the supported direction).
Stop application writes to the old cluster first: changes made during the dump are not copied.

Results: exit 0 only if every database restored with no errors and the counts match. Otherwise the summary names
the failed/different databases, the dumps are kept, and each database has its own log (`db_N.log`; `manifest.tsv`
maps N to names). Fix the cause, drop that database on the new cluster, and re-run with `--db <name>`.
On success the dump files are deleted (logs kept) unless `--keep-dumps`. The dump directory is mode 700.

TDE: no passphrase is needed (the new service already unwraps its own key). Dump files of an encrypted cluster are
**not** encrypted, so they're kept in a 700 directory and deleted after success. If the old cluster uses TDE and the
new one doesn't, the script stops unless you pass `--allow-unencrypted-target`.
