# EPAS 17 SSL Setup and Deployment Toolkit

This directory contains deployment configuration templates and automated scripts to configure SSL/TLS for EnterpriseDB Postgres Advanced Server (EPAS) 17 using an encrypted private key and a file-based passphrase architecture.

---

## Architecture Overview

The setup enforces end-to-end security for EPAS 17 database environments using standard PEM bundles:

* **Encrypted Key Architecture:** The database private key (`server.key`) is stored in an encrypted format.
* **Automated Decryption at Startup:** The passphrase is held in a protected file (`.ssl_key_passphrase`, `0400` permissions) accessed exclusively by an automated wrapper script (`read_passphrase.sh`, `0500` permissions) via the PostgreSQL parameter `ssl_passphrase_command`.
* **Strict PEM Bundle Order:** To prevent key-certificate mismatches, the bundle structure is validated in the following order:
  1. `-----BEGIN ENCRYPTED PRIVATE KEY-----` (Private Key)
  2. `-----BEGIN CERTIFICATE-----` (Server / Leaf Certificate)
  3. `-----BEGIN CERTIFICATE-----` (Intermediate CA Certificate(s) - optional)
  4. `-----BEGIN CERTIFICATE-----` (Root CA Certificate)

---

## File Summary

| File Name | Purpose |
| :--- | :--- |
| `../../conf/site.env.example` | Shared environment template (paths, ports, service names, network access rules) used by this module. |
| `epas-ssl-setup.sh` | Main deployment script. Parses environmental settings, extracts key/cert files, validates RSA modulus alignment, generates `ssl.conf` and `pg_hba.conf`, and reloads EPAS. |
| `generate-selfsigned-san.sh` | Generates one self-signed bundle valid for primary AND standby (test clusters). IPs from `PRIMARY_HOST`/`STANDBY_HOST`, DNS names from `PRIMARY_FQDN`/`STANDBY_FQDN` in `conf/site.env`. |
| `generate-selfsigned-single.sh` | Generates a single-host self-signed bundle (`[output] [domain] [days]`) for development or single-node testing. |
| `epas-migrate-ssl-conf.sh` | Major upgrade helper: copies the SSL settings from the OLD cluster's `postgresql.conf` into the new cluster's `conf.d/ssl.conf` (defaults from `conf/site.env`; an existing `ssl.conf` is kept as `.bak_<timestamp>`). |
| `tests/preflight-check.sh <SECURITY_TOP>` | Checks the installed key matches the certificate (uses `.ssl_key_passphrase`). |
| `tests/verify-db-ssl.sh` | Confirms the running EPAS reports `ssl = on`. |

---

## Quick Start Guide

### Prerequisites
* RHEL / Rocky Linux / CentOS or compatible system running EPAS 17.
* `root` or `sudo` privileges on target host(s).
* OpenSSL CLI installed.

---

### Step 1: Prepare Environment Configuration

1. Copy the example environment file:
   ```bash
   cp conf/site.env.example conf/site.env   # from the repo root
   ```
2. Edit `conf/site.env` to reflect your target database environment and network topography:
   * **Directories:** Adjust `DATA_TOP` and `SECURITY_TOP` paths.
   * **Service & System User:** Set `SYSTEM_USER` (default: `enterprisedb`) and `SERVICE_NAME` (default: `edb-as-17`).
   * **Networking:** Update `PRIMARY_HOST`, `STANDBY_HOST`, and `SUBNET_CIDR`.

---

### Step 2: Generate or Obtain SSL Bundle

Choose one of the following methods depending on your target architecture.

#### Option A: High Availability Cluster (Multi-Host SAN)
Use this option if you are deploying a Primary/Standby pair with `generate-selfsigned-san.sh`.

1. Open `generate-selfsigned-san.sh` and update hostnames and IP addresses:
   ```bash
   PRIMARY_HOST="server1.example.com"
   PRIMARY_IP="192.168.1.11"
   STANDBY_HOST="server2.example.com"
   STANDBY_IP="192.168.1.12"
   ```
2. Run the script:
   ```bash
   chmod +x generate-selfsigned-san.sh
   ./generate-selfsigned-san.sh /tmp/epas_bundle.pem 365
   ```
3. Enter and confirm the server key passphrase when prompted.
4. Distribute `/tmp/epas_bundle.pem` to both host machines.

#### Option B: Single Host Environment
Use this option for standalone instances or single-server testing environments using `generate-selfsigned-single.sh`.

```bash
chmod +x generate-selfsigned-single.sh
./generate-selfsigned-single.sh /tmp/epas_bundle.pem db.example.com 365
```

#### Option C: Commercial or Enterprise CA Certificates
If using certificates issued by an internal PKI or public CA:
Ensure the PEM file is concatenated in the enforced order:
```bash
cat server.key leaf.crt intermediate.crt root.crt > /tmp/epas_bundle.pem
```

---

### Step 3: Run the SSL Setup Script

Execute `epas-ssl-setup.sh` as `root` (or via `sudo`), specifying your environment file and certificate bundle:

```bash
chmod +x epas-ssl-setup.sh
sudo ./epas-ssl-setup.sh --env ../../conf/site.env -b /tmp/epas_bundle.pem
```

#### What the Setup Script Performs Automagically:
1. Validates the existence of required environment variables.
2. Verifies that the private key is encrypted and placed **before** certificate blocks in the PEM bundle.
3. Prompts for key passphrase and tests key decryption via OpenSSL.
4. Writes encrypted key to `${SECURITY_TOP}/server.key` (`0600`).
5. Stores passphrase in `${SECURITY_TOP}/.ssl_key_passphrase` (`0400`, owned by system user).
6. Generates helper wrapper `${SECURITY_TOP}/read_passphrase.sh` (`0500`).
7. Splits bundle into `${SECURITY_TOP}/server_chained.crt` and `${SECURITY_TOP}/root.crt`.
8. Verifies RSA key modulus against leaf certificate and checks expiration.
9. Appends `include_dir = 'conf.d'` to `postgresql.conf` and creates `${DATA_TOP}/conf.d/ssl.conf`.
10. Generates restrictive `${DATA_TOP}/pg_hba.conf` enforcing SSL for replication and local subnets.
11. Restarts the database service using `systemctl` and checks runtime SSL status.

---

## Verification & Troubleshooting

### Check Database SSL Status
Run the following query as the database administrative user:
```bash
su - enterprisedb -c "psql -p 5444 -d postgres -c 'SHOW ssl;'"
```
**Expected Output:**
```text
 ssl 
-----
 on
(1 row)
```

### File Permission Matrix Verification
Check that file permissions in `${SECURITY_TOP}` match requirements:

```bash
ls -la /u001/data/as17/security/
```

* `.ssl_key_passphrase` $\rightarrow$ `0400` (`enterprisedb:enterprisedb`)
* `read_passphrase.sh` $\rightarrow$ `0500` (`enterprisedb:enterprisedb`)
* `server.key` $\rightarrow$ `0600` (`enterprisedb:enterprisedb`)
* `server_chained.crt` $\rightarrow$ `0644` (`enterprisedb:enterprisedb`)
* `root.crt` $\rightarrow$ `0644` (`enterprisedb:enterprisedb`)

---

## Security Notes

1. **Passphrase Storage:** The key passphrase is written to a hidden file (`.ssl_key_passphrase`). Permissions are restricted to `0400` owned by `SYSTEM_USER`. Ensure filesystem backups exclude or encrypt security metadata directories if exposed outside restricted infrastructure.
2. **TDE Command Placeholders:** The `TDE_WRAP_CMD` and `TDE_UNWRAP_CMD` variables in `conf/site.env.example` contain placeholder credentials. Always populate these settings dynamically via an enterprise secrets manager (e.g., HashiCorp Vault) during deployment pipelines.

---

## Behaviour notes (2026-10-17)

- Config comes from `conf/site.env` automatically (or `--env <file>`); the script prints the settings and asks **Proceed? (y/N)** before changing anything (`--yes` skips the question).
- Before restarting, the new configuration is validated by the EPAS binary itself (`edb-postgres -C`). If EPAS rejects it, the script **stops without restarting** — the running server is unaffected — and points to the backup folder.
- `pg_hba.conf` is **merged, not replaced**: the SSL rules live in a marked block at the top
  (`# >>> edb_toolkit SSL rules …` / `# <<< edb_toolkit SSL rules <<<`) and every existing rule is kept below it.
  Re-running replaces only that block. Non-SSL replication from `SUBNET_CIDR` is rejected; SSL replication from
  other hosts (e.g. a DR standby) still works through your existing replication rule (such as the one
  `epas-prep-primary.sh` adds). Don't edit inside the marked block — put your own rules below it.
- **Automatic rollback:** if EPAS does not come back up after the restart, the script restores every file it
  replaced (ssl.conf, pg_hba.conf, key, certificates), removes an `ssl.conf` that did not exist before, restarts
  again and tells you; the failed files are kept in `SECURITY_TOP/.backup-<timestamp>/failed-new-files`.
