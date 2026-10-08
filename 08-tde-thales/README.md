# EPAS TDE with Thales CipherTrust Manager — Automation Scripts

Automates Transparent Data Encryption (TDE) for **EDB Postgres Advanced Server (EPAS) 17 on RHEL 9** using **Thales CipherTrust Manager** via KMIP. Fits the existing `epas-base-build.sh` conventions: env-file driven, sources `../config/logger.sh`, `set -euo pipefail`, safeguards before destructive steps.

> **Critical:** TDE must be enabled at `initdb` time. It cannot be enabled on an existing cluster — choose the script that matches your situation.

---

## Scripts at a Glance

| Script | Use when | What it does |
|---|---|---|
| `tde-thales-setup.sh` | **New** cluster, no `PGDATA` yet | Installs KMIP client → stages certs → preflight roundtrip → `initdb --data-encryption=256` → start → verify |
| `tde-openssl-to-thales-migrate.sh` | Cluster **already TDE-enabled** with an openssl passphrase | Stops DB → preflight roundtrip → unwraps DEK with old openssl passphrase → re-wraps DEK with Thales → updates `postgresql.conf` → start → verify |

---

## 1. `tde-thales-setup.sh` — New TDE-Enabled Cluster

### Prerequisites
- EPAS 17 installed (binaries present)
- Thales CipherTrust Manager reachable on KMIP port **5696**
- An **AES-256 key created on Thales** with usage: Encrypt, Decrypt, Wrap Key, Unwrap Key — note its **UUID**
- Client certificates from Thales: `key.pem`, `cert.pem`, `ca.pem`
- EDB repo configured (`sudo dnf repolist | grep enterprisedb`)

### Usage
```bash
sudo ./tde-thales-setup.sh --env /path/to/deploy.env
```

### Environment file (`deploy.env`)
```bash
# ---- Thales CipherTrust Manager (required) ----
THALES_HOST=cm.thales.example.com      # FQDN or IP
THALES_PORT=5696                        # optional, default 5696
THALES_USER=edb-kmip-user
THALES_PASS='<inject from secrets manager — never hardcode>'
THALES_KEY_UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
THALES_KEYFILE=/secure/path/key.pem
THALES_CERTFILE=/secure/path/cert.pem
THALES_CAFILE=/secure/path/ca.pem

# ---- EPAS (required) ----
EPAS_VERSION=17
SYSTEM_USER=enterprisedb
SYSTEM_GROUP=enterprisedb
PRIMARY_PORT=5444
BINARY_TOP=/usr/edb/as17
DATA_TOP=/var/lib/edb-as/17/data

# ---- Optional ----
DSM_DIR=/var/lib/edb/dsm               # where pykmip.conf + certs are staged
```

### What it does (in order)
1. **Validates** all required variables; refuses to run if a cluster already exists without TDE.
2. **Installs** `python3-pykmip` and `edb-tde-kmip-client` (idempotent).
3. **Stages** certificates into `$DSM_DIR` (`key.pem` mode 600, owned by `$SYSTEM_USER`) and writes `pykmip.conf` (mode 600).
4. **Preflight roundtrip**: encrypts + decrypts a test value via KMIP. **Aborts before `initdb` if Thales is unreachable** — you never half-initialize a cluster.
5. **Exports** `PGDATAKEYWRAPCMD` / `PGDATAKEYUNWRAPCMD` (with `--variant=thales`, which Thales requires for its `IV‖CT` format).
6. Runs **`initdb --data-encryption=256`** as `$SYSTEM_USER`; verifies `data_encryption_key_unwrap_command` was persisted to `postgresql.conf`.
7. **Starts** via systemd (or `pg_ctl` fallback) and verifies `SELECT data_encryption_version FROM pg_control_init();` returns `1`.

---

## 2. `tde-openssl-to-thales-migrate.sh` — Migrate Existing openssl TDE to Thales

Use this when the cluster is already TDE-enabled with a passphrase-based openssl wrap/unwrap command and you want to move key custody to Thales CM. The **data files are not re-encrypted** — only the DEK envelope (`key.bin`) is unwrapped and re-wrapped, so downtime is minimal.

### Prerequisites
- Existing TDE cluster at `$DATA_TOP` (contains `global/pg_encryption/key.bin`)
- The **current openssl passphrase** (from your secrets manager)
- A **new AES-256 key + UUID** created on Thales for re-wrapping
- Thales client certificates
- Maintenance window (database is stopped during the swap)

### Usage
```bash
sudo ./tde-openssl-to-thales-migrate.sh --env /path/to/migrate.env
```

### Environment file (`migrate.env`)
```bash
# ---- Old openssl TDE (required) ----
OLD_TDE_PASSPHRASE='<current openssl passphrase — inject from secrets manager>'

# ---- Thales CM (required) ----
THALES_HOST=cm.thales.example.com
THALES_PORT=5696
THALES_USER=edb-kmip-user
THALES_PASS='<inject from secrets manager>'
THALES_KEY_UUID=yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy   # NEW key on Thales
THALES_KEYFILE=/secure/path/key.pem
THALES_CERTFILE=/secure/path/cert.pem
THALES_CAFILE=/secure/path/ca.pem

# ---- EPAS (required) ----
EPAS_VERSION=17
SYSTEM_USER=enterprisedb
SYSTEM_GROUP=enterprisedb
PRIMARY_PORT=5444
DATA_TOP=/var/lib/edb-as/17/data

# ---- Optional ----
DSM_DIR=/var/lib/edb/dsm
PG_ENCRYPTION_DIR=${DATA_TOP}/global/pg_encryption
```

### What it does (in order)
1. **Stops** the database and waits until all postgres processes are down.
2. Installs/stages KMIP packages, certs, and `pykmip.conf` (same as setup script).
3. **Preflight Thales roundtrip** — aborts before touching `key.bin` if anything is wrong.
4. **Backs up** `key.bin` → `bak_migrate_<ts>/key.bin.openssl` and `postgresql.conf` → `bak_migrate_<ts>/postgresql.conf.bak`.
5. **Unwraps the DEK** with `openssl enc -d -aes-256-cbc -pass pass:$OLD_TDE_PASSPHRASE`. Wrong passphrase = abort, nothing changed.
6. **Re-wraps the DEK** with the Thales KMIP key UUID (`--variant=thales`).
7. **Updates** `data_encryption_key_unwrap_command` in `postgresql.conf` (old line commented out for audit, new line appended).
8. **Starts** the database; verifies:
   - `pg_isready` — proves the new unwrap command works (server won't start otherwise)
   - `data_encryption_version = 1`
   - A real data read (`SELECT count(*) FROM pg_database`) — proves the DEK unwraps correctly in practice

### Rollback
If startup fails, the script prints the exact rollback commands. Manually:
```bash
sudo systemctl stop edb-as-17.service
sudo cp $DATA_TOP/global/pg_encryption/bak_migrate_<ts>/key.bin.openssl $DATA_TOP/global/pg_encryption/key.bin
sudo cp $DATA_TOP/global/pg_encryption/bak_migrate_<ts>/postgresql.conf.bak $DATA_TOP/postgresql.conf
sudo systemctl start edb-as-17.service
```

> **Note:** the openssl unwrap assumes the standard EDB example cipher (`-aes-256-cbc` with `-pass pass:`). If your original setup used a keyfile (`-pass file:`) or a different cipher, parameterize `OLD_TDE_UNWRAP_CMD` in the script instead.

---

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

Both scripts enforce this automatically (`chown` + `chmod 0700` after `mkdir`).

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
