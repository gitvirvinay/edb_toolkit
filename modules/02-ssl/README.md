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
| `epas-migrate-ssl-conf.sh` | Major upgrade helper, run as `enterprisedb` (`04-upgrade/epas-major-pgupgrade.sh` runs it for you): writes the OLD cluster's effective SSL settings (postgresql.conf, its includes and conf.d, postgresql.auto.conf) to the new cluster's `conf.d/ssl.conf`. `--check` only reports. Refuses, changing nothing, if an SSL file is inside the old data directory or a relative path. |
| `epas-ssl-relocate.sh [--to DIR] [--remove-old]` | Moves an EXISTING cluster's SSL key/certificates out of PGDATA (default to `/etc/edb/ssl`): rebuilds a bundle from the current files (passphrase via `ssl_passphrase_command`; an unencrypted key is encrypted with a new random passphrase) and installs it with `epas-ssl-setup.sh` - same certificate, `pg_hba.conf` untouched, applied with a reload. Old files in PGDATA are kept and listed; `--remove-old` (now or later) deletes them. |
| `check-cert.sh [--days N] [cert]` | Read-only report on this server's certificate: names, issuer, expiry, and the same name checks as the setup. Exit 0 ok, 1 act now (missing, expired, wrong names), 2 expires within N days (default 30) - suitable for cron or monitoring. |
| `tests/preflight-check.sh <SECURITY_TOP>` | Checks the installed key matches the certificate (uses `.ssl_key_passphrase`). |
| `tests/verify-db-ssl.sh` | Confirms the running EPAS reports `ssl = on`. |

---

## Quick Start Guide

### Prerequisites
* RHEL / Rocky Linux / CentOS or compatible system running EPAS 17.
* **Root, once per host** (nothing else needs root):
  * `SECURITY_TOP` (default `/etc/edb/ssl`) owned by `enterprisedb`, mode `0700`. `epas-base-build-root.sh` creates it; on an existing host: `sudo install -d -o enterprisedb -g enterprisedb -m 0700 /etc/edb/ssl`.
  * For a systemd-managed cluster, the sudoers rule that lets `enterprisedb` restart it: `sudo install -m 0440 conf/sudoers.d/epas-automation /etc/sudoers.d/epas-automation && sudo visudo -c`.
* Everything in this module then runs as the database OS user (`enterprisedb`). `epas-ssl-setup.sh` refuses to run as root.
* OpenSSL CLI installed.

---

### Step 1: Prepare Environment Configuration

1. Copy the example environment file:
   ```bash
   cp conf/site.env.example conf/site.env   # from the repo root
   ```
2. Edit `conf/site.env` to reflect your target database environment and network topography:
   * **Directories:** Adjust `DATA_TOP`. Keep `SECURITY_TOP=/etc/edb/ssl`: one directory per host, **outside PGDATA**, so `pg_basebackup`, standby rebuilds and backups never copy this host's key and passphrase to another host, and a major upgrade (new PGDATA) keeps using the same files.
   * **Service & System User:** Set `SYSTEM_USER` (default: `enterprisedb`) and `SERVICE_NAME` (default: `edb-as-17`).
   * **Networking:** Update `PRIMARY_HOST`, `STANDBY_HOST`, and `SUBNET_CIDR`.

---

### Step 2: Generate or Obtain SSL Bundle

Choose one of the following methods depending on your target architecture.

#### Option A: High Availability Cluster (Multi-Host SAN)
Use this option if you are deploying a Primary/Standby pair with `generate-selfsigned-san.sh`.

Lab and test use only: one shared certificate for both hosts. For SIT and above, get one certificate per server from your CA (each with its own FQDN/IP plus every shared name clients use, such as the EFM VIP or DNS alias).

1. Set the hosts in `conf/site.env`: IPs in `PRIMARY_HOST` / `STANDBY_HOST`, optional DNS names in `PRIMARY_FQDN` / `STANDBY_FQDN`.
2. Run the script (as any user; no root needed):
   ```bash
   ./generate-selfsigned-san.sh /tmp/epas_bundle.pem 365
   ```
3. Enter and confirm the server key passphrase when prompted.
4. Distribute `/tmp/epas_bundle.pem` to both host machines.

#### Option B: Single Host Environment
Use this option for standalone instances or single-server testing environments using `generate-selfsigned-single.sh`.

```bash
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

Run `epas-ssl-setup.sh` as the database OS user, never as root. The bundle must be readable by that user; if you generated it as someone else, hand it over first:

```bash
sudo install -o enterprisedb -m 0600 /tmp/epas_bundle.pem /tmp/epas_bundle.ent.pem   # only if needed
sudo -iu enterprisedb /opt/dba/edb_toolkit/modules/02-ssl/epas-ssl-setup.sh -b /tmp/epas_bundle.ent.pem
```

Why not root: every file it writes is owned by `enterprisedb`, in directories `enterprisedb` controls. Root writing there can be redirected by a symbolic link the database account planted, turning "DB account" into "root". A running cluster is **reloaded** (no downtime, no sudo). Only a stopped cluster or `--restart` needs a restart: through the sudoers rule (`sudo systemctl restart edb-as-17`), or `pg_ctl` for a cluster started with `pg_ctl`.

Options: `--restart` (restart instead of reload), `--passphrase-file FILE` (no prompt; automation), `--security-top DIR` (install into DIR instead of `SECURITY_TOP`), `--names-warn` (name problems only warn), `--no-hba` (leave `pg_hba.conf` alone).

#### What the Setup Script Performs Automagically:
1. Checks it runs as `SYSTEM_USER` (not root), that `SECURITY_TOP` exists and is owned by it, and how the cluster will be restarted (for systemd: that the sudoers rule is in place). All before anything changes.
2. Verifies that the private key is encrypted and placed **before** certificate blocks in the PEM bundle.
3. Prompts for key passphrase and tests key decryption via OpenSSL (passphrase read from a private file, never on a command line).
4. Builds every new file in a private temp directory and runs the checks there: RSA key modulus against the leaf certificate, expiry, chain, and **the certificate's names** (see *Certificate names* below: valid for this server and for every name in `SSL_SHARED_NAMES`). A failed check changes nothing.
5. Backs up the current files to `${SECURITY_TOP}/.backup-<timestamp>-XXXX`, then replaces each one atomically (temp file + `mv`; a symbolic link is refused):
   * `${SECURITY_TOP}/server.key` (`0600`), `.ssl_key_passphrase` (`0400`), `read_passphrase.sh` (`0500`)
   * `${SECURITY_TOP}/server_chained.crt` and `root.crt` (`0644`)
   * `${DATA_TOP}/conf.d/ssl.conf`, the SSL block of `${DATA_TOP}/pg_hba.conf`, and `include_dir = 'conf.d'` in `postgresql.conf` if missing.
6. Lets EPAS parse the new configuration (`edb-postgres -C`); if it is rejected, the old files are restored and nothing is restarted.
7. Applies it: a **running** cluster is reloaded (`pg_ctl reload`; `ssl_passphrase_command_supports_reload = on` lets the encrypted key load without a restart), then checked: no errors in `pg_file_settings` / `pg_hba_file_rules`, and the server presents the **new** certificate (`openssl s_client -starttls postgres` on 127.0.0.1, compared by SHA-256 fingerprint). If not, the old files are restored and reloaded - EPAS never stops. A stopped cluster (or `--restart`) is (re)started instead: `sudo systemctl restart <unit>` or `pg_ctl restart`; if it does not come back, the old files are restored and it is restarted again.

---

## Certificate names

Clients using `sslmode=verify-full` check that the name they connected to is in the server's certificate. `epas-ssl-setup.sh`, `check-cert.sh` and the standby rebuild check every certificate against two settings in `conf/site.env`:

| Setting | Meaning | Example |
| --- | --- | --- |
| `SSL_HOST_NAME` | this server's own name in its certificate; empty = `hostname -f`, `hostname -s` or one of its IPs | `db01.example.com` |
| `SSL_SHARED_NAMES` | names clients use that move between nodes (EFM VIP DNS name, DB alias, DR alias), space-separated; every node's certificate must contain them | `pgprod.example.com` |

| Result | When |
| --- | --- |
| stop, nothing changed | the certificate is not valid for this server, or misses a name in `SSL_SHARED_NAMES` |
| warning | it is also valid for another node (`PRIMARY_HOST`/`STANDBY_HOST`/`*_FQDN`): a shared certificate, one private key on several servers - fine for DEV/lab, for SIT/PAT/PROD use one per server; a wildcard; no SAN |

**Renewing a certificate** is the same command with the new bundle, on each server (DR, then standby, then primary). It is applied with a reload, so there is no downtime and no EFM failover risk.

```bash
/opt/dba/edb_toolkit/modules/02-ssl/check-cert.sh          # any user; exit 0 / 1 / 2
```

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
ls -la /etc/edb/ssl/
```

* `.ssl_key_passphrase` $\rightarrow$ `0400` (`enterprisedb:enterprisedb`)
* `read_passphrase.sh` $\rightarrow$ `0500` (`enterprisedb:enterprisedb`)
* `server.key` $\rightarrow$ `0600` (`enterprisedb:enterprisedb`)
* `server_chained.crt` $\rightarrow$ `0644` (`enterprisedb:enterprisedb`)
* `root.crt` $\rightarrow$ `0644` (`enterprisedb:enterprisedb`)

---

## Security Notes

1. **Passphrase Storage:** The key passphrase is written to a hidden file (`.ssl_key_passphrase`). Permissions are restricted to `0400` owned by `SYSTEM_USER`. Ensure filesystem backups exclude or encrypt security metadata directories if exposed outside restricted infrastructure.
2. **Keep SSL files out of PGDATA:** with `SECURITY_TOP` inside the data directory (the old layout, e.g. `/u001/data/as17/security`), every `pg_basebackup`, standby rebuild and backup carries this host's key **and** passphrase. The script still accepts that layout but warns. To move: root creates `/etc/edb/ssl` once (`sudo install -d -o enterprisedb -g enterprisedb -m 0700 /etc/edb/ssl`), then as `enterprisedb` run `epas-ssl-relocate.sh` (reload, no downtime), check, run `epas-ssl-relocate.sh --remove-old`, and set `SECURITY_TOP=/etc/edb/ssl` in `conf/site.env`. Old backups still contain the old key, so for production plan to re-issue the certificate with a new key.

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

## Behaviour notes (2026-11-08)

- `epas-ssl-setup.sh` runs as `SYSTEM_USER` and refuses root. The restart uses `sudo -n systemctl restart <unit>` (sudoers rule) or `pg_ctl`; the script checks this works before it changes anything.
- `SECURITY_TOP` defaults to `/etc/edb/ssl` (outside PGDATA), created once by root.
- New files are built and checked in a private temp directory, then installed atomically; symbolic links are refused. If EPAS rejects the configuration, the previous files are now restored too (before, they stayed in place unapplied).
- No passphrase on any command line (setup and both generators use `openssl -pass… file:`).
- Certificate names are checked (`SSL_HOST_NAME`, `SSL_SHARED_NAMES`); `check-cert.sh` added for cron/monitoring;
  `epas-migrate-ssl-conf.sh` rewritten (DB user, effective settings, `--check`, refuses SSL files inside the old data
  directory) and called by `04-upgrade/epas-major-pgupgrade.sh`; the standby rebuild checks SSL before starting.

## Behaviour notes (2026-11-09)

- A running cluster is now reloaded, not restarted, and the reload is verified (config errors, and the certificate actually presented). A failed reload is rolled back without stopping EPAS. `--restart` keeps the old behaviour.
- New options `--passphrase-file`, `--security-top`, `--names-warn`, `--no-hba`; new script `epas-ssl-relocate.sh`.
- Tested against a real PostgreSQL 16 server: first install on a running cluster, renewal with a new encrypted key (same postmaster, no restart), a reload that does not take (rolled back), refusal of another server's certificate, move from inside PGDATA and `--remove-old`.
