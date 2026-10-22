# EPAS TDE with Thales CipherTrust Manager

Transparent Data Encryption (TDE) for **EDB Postgres Advanced Server (EPAS) on RHEL** with the data key wrapped by
**Thales CipherTrust Manager** through KMIP. Settings: `conf/tde.env` (default for these scripts; it loads
`conf/site.env` and adds the Thales settings). Inject `THALES_PASS` (and `OLD_TDE_PASSPHRASE` if used) from your
secrets manager: `export THALES_PASS=...` before running.

| Script | Use when | What it does |
|---|---|---|
| `tde-thales-setup.sh` | **New** cluster (empty `DATA_TOP`) | KMIP client + certificates → round-trip test → `initdb --data-encryption=256` with Thales wrap/unwrap → test start, `data_encryption_version=1`, stop |
| `tde-openssl-to-thales-migrate.sh` | Cluster **already** encrypted with an openssl passphrase | Re-wraps only `pg_encryption/key.bin` with Thales (data files are not re-encrypted); one short restart; automatic rollback |
| `thales-kmip.sh` | (helper, sourced by both) | package install, certificate staging, `pykmip.conf`, round-trip test |

The wrapped data key lives in **`<DATA_TOP>/pg_encryption/key.bin`** (EDB docs: "Data encryption key").

## Prerequisites (both)
- EPAS installed (`SRC_BINARY_DIR/bin`), EDB repository configured (`dnf repolist | grep enterprisedb`)
- Thales CipherTrust Manager reachable on KMIP port 5696
- An AES-256 key on Thales with usage Encrypt + Decrypt (and Wrap/Unwrap) — its UUID goes in `THALES_KEY_UUID`
- Client certificates from Thales: key, cert, CA (`THALES_KEYFILE`, `THALES_CERTFILE`, `THALES_CAFILE`)

## 1. `tde-thales-setup.sh` — new TDE cluster

```bash
export THALES_PASS='...'                                   # from the secrets manager
sudo -E modules/08-tde/tde-thales-setup.sh                 # conf/tde.env by default
sudo modules/01-provision/epas-base-build.sh               # then: keeps the cluster, adds systemd drop-in + conf.d
sudo systemctl start edb-as-17
```

It runs **instead of** the passphrase initdb in `epas-base-build.sh` (that script skips initdb when the cluster
exists). Steps: refuses if `DATA_TOP` already holds a cluster (non-TDE → use 04-upgrade into a new TDE cluster;
passphrase TDE → use the migrate script; already KMIP → nothing to do) → installs `python3-pykmip` and
`edb-tde-kmip-client` → stages certificates and `pykmip.conf` in `DSM_DIR` → encrypts and decrypts a test value
through Thales (**stops before initdb if that fails**) → `initdb --data-encryption=256` with the Thales
`PGDATAKEYWRAPCMD`/`PGDATAKEYUNWRAPCMD` (initdb records the unwrap command in `postgresql.conf`) → starts the
server with `pg_ctl` on `PRIMARY_PORT`, checks `data_encryption_version = 1`, stops it again.
If the check fails, the message says so: empty `DATA_TOP` (no data in it yet) before re-running.

## 2. `tde-openssl-to-thales-migrate.sh` — move an existing cluster's key to Thales

```bash
export THALES_PASS='...'
sudo -E modules/08-tde/tde-openssl-to-thales-migrate.sh    # run on the primary AND on every standby
```

Set `THALES_KEY_UUID` to the Thales key that should wrap the data key from now on.
The current key is unwrapped with **the server's own `data_encryption_key_unwrap_command`** (from
`postgresql.conf`), so whatever cipher/passphrase setup the cluster has is used as-is. Override with
`OLD_UNWRAP_CMD` (must contain `%p`) if needed; a command written as `-pass env:OLD_TDE_PASSPHRASE` gets the
exported `OLD_TDE_PASSPHRASE`.

Steps (follows EDB's documented re-wrap: *old unwrap | new wrap > key.bin.new*):
1. While the database keeps running: KMIP setup and round-trip test; old unwrap piped straight into the Thales
   wrap → `key.bin.new` (the plain data key is never written to disk or held in a shell variable); both copies are
   unwrapped and their SHA-256 compared — any difference stops the run with `key.bin` unchanged.
2. Backup of `key.bin` and `postgresql.conf` to `<parent of DATA_TOP>/tde_migrate_<timestamp>/` (700).
3. Stop `SERVICE_NAME` → `key.bin.new` replaces `key.bin` → the old unwrap line is commented out (dated) and the
   Thales one appended → start → `data_encryption_version = 1`.
4. If the start or the check fails: **automatic rollback** (old `key.bin` and `postgresql.conf` restored, service
   started again); the Thales copy is kept as `key.bin.thales.failed` for investigation.

Refused up front: no `key.bin`; already KMIP (nothing to do); the unwrap command also set in
`postgresql.auto.conf` or `conf.d/*.conf` (it would override the change).

Afterwards keep the backup's `key.bin.openssl` **and the old passphrase**: backups taken before the migration
contain the old wrapping. The old unwrap line stays in `postgresql.conf` as a comment.

## General Notes

- **`--variant=thales` is mandatory** on both encrypt and decrypt: Thales' `Decrypt` expects `Data = IV‖CT` (no separate `IVCounterNonce` field), unlike standard KMIP.
- **RHEL 9 crypto policy:** TLS 1.2+, RSA ≥ 2048 — ensure Thales certificates comply.
- **TDE encrypts data at rest** (data files, WAL, temp files). Shared buffers remain unencrypted.
- Secrets (`THALES_PASS`, `OLD_TDE_PASSPHRASE`) should be injected at runtime from your secrets manager (e.g., Vault, via `env` file perms 600) — never committed to version control.
- The unwrap command persisted in `postgresql.conf` runs on **every server start**; if Thales CM is down at startup, the database will not start. Ensure HA for CipherTrust Manager in production.


## DSM Directory Ownership (`/var/lib/edb/dsm/`)

The unwrap command runs **as the database OS user** at every server start, so the DSM directory and its contents must be owned by `enterprisedb`:

| Path | Owner | Mode |
|---|---|---|
| `/var/lib/edb/dsm/` | `enterprisedb:enterprisedb` | `700` |
| `pykmip.conf` | `enterprisedb:enterprisedb` | `600` (contains Thales credentials) |
| `key.pem` | `enterprisedb:enterprisedb` | `600` (client private key) |
| `cert.pem`, `ca.pem` | `enterprisedb:enterprisedb` | `644` |

Both scripts set this automatically (`thales_stage` in `thales-kmip.sh`); an existing `pykmip.conf` is backed up first.

## Verification (both scripts)
```sql
SELECT data_encryption_version FROM pg_control_init();   -- expect 1
```
```bash
grep data_encryption_key_unwrap_command $DATA_TOP/postgresql.conf
```

## References
- [EDB TDE Documentation](https://www.enterprisedb.com/docs/tde/latest/)
- [Using Thales KMS with EDB TDE](https://www.enterprisedb.com/docs/tde/latest/secure_key/key_store/thales/)
- [Thales REST API Integration](https://www.enterprisedb.com/docs/tde/latest/secure_key/key_store/thales/thales_restapi/)
