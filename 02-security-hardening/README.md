# EPAS SSL Setup Toolkit

Self-contained SSL certificate generation and deployment scripts for **EDB Advanced Server 17** (EPAS 17) on RHEL-compatible systems.

---

## Scripts

| File | Purpose |
|------|---------|
| `epas-ssl-setup.sh` | Deploys an **encrypted** PEM bundle, generates `ssl.conf` + `pg_hba.conf`, and restarts the cluster. |
| `generate-selfsigned.sh` | Creates a **self-signed, encrypted, multi-SAN** PEM bundle for one or more hosts. |
| `deploy_ssl.env` | Site-specific configuration (paths, users, network topology). |

---

## Quick Start — Single Server

### 1. Create your environment file

```bash
mkdir -p /u001/data/as17/security
cat > /u001/data/as17/security/deploy_ssl.env <<'EOF'
DATA_TOP="/u001/data/as17"
SECURITY_TOP="/u001/data/as17/security"
SYSTEM_USER="enterprisedb"
SYSTEM_GROUP="enterprisedb"
SERVICE_NAME="edb-as-17"
PRIMARY_PORT=5444
PRIMARY_HOST="192.168.1.11"
STANDBY_HOST="192.168.1.12"
SUBNET_CIDR="192.168.1.0/24"
EOF
chmod 600 /u001/data/as17/security/deploy_ssl.env
```

### 2. Generate a self-signed bundle

```bash
./generate-selfsigned.sh /tmp/server_bundle.pem
```

You will be prompted to set a **passphrase** for the private key. Remember it.

### 3. Deploy on the server

```bash
sudo ./epas-ssl-setup.sh \
    --env /u001/data/as17/security/deploy_ssl.env \
    --bundle /tmp/server_bundle.pem
```

You will be prompted for the **same passphrase** you set in step 2.

The script will:
- Keep `server.key` **encrypted on disk**
- Store the passphrase in `.ssl_key_passphrase` (hidden, `0400`)
- Create a helper script `read_passphrase.sh` for PostgreSQL startup
- Generate `ssl.conf` in `${DATA_TOP}/conf.d/`
- Generate `pg_hba.conf` with `hostssl` enforcement
- Restart `edb-as-17`
- Verify `ssl = on` after restart

---

## Quick Start — Primary / Standby Pair

Both servers must present a certificate whose **SAN** covers both hostnames/IPs.

### 1. Edit `generate-selfsigned.sh`

Set both hosts in the script header:

```bash
PRIMARY_HOST="server1.example.com"
PRIMARY_IP="192.168.1.11"
STANDBY_HOST="server2.example.com"
STANDBY_IP="192.168.1.12"
```

### 2. Generate once, copy twice

```bash
# Generate on any secure build host
./generate-selfsigned.sh /tmp/dual-host-bundle.pem

# Copy to both servers
scp /tmp/dual-host-bundle.pem root@server1:/tmp/
scp /tmp/dual-host-bundle.pem root@server2:/tmp/
```

### 3. Deploy on each server

Run the setup script **on server1** and **on server2** using the **same bundle**:

```bash
sudo ./epas-ssl-setup.sh \
    --env /u001/data/as17/security/deploy_ssl.env \
    --bundle /tmp/dual-host-bundle.pem
```

> **Note:** The passphrase you type must be the same on both nodes because they share the same encrypted private key.

---

## Security Model

| File | State | Permissions | Owner | Purpose |
|------|-------|-------------|-------|---------|
| `server.key` | **Encrypted** | `0600` | `enterprisedb` | Private key (never decrypted to disk) |
| `.ssl_key_passphrase` | Plaintext | `0400` | `enterprisedb` | Passphrase read by PostgreSQL at startup |
| `read_passphrase.sh` | Script | `0500` | `enterprisedb` | `ssl_passphrase_command` target |
| `server_chained.crt` | PEM | `0644` | `enterprisedb` | Server certificate + intermediates |
| `root.crt` | PEM | `0644` | `enterprisedb` | Trusted root CA for client verification |

### How Passphrase Retrieval Works

1. `systemctl start edb-as-17`
2. PostgreSQL reads `ssl_passphrase_command = '/u001/data/as17/security/read_passphrase.sh'`
3. It executes the helper as `enterprisedb`
4. Helper runs `cat .ssl_key_passphrase`
5. PostgreSQL receives passphrase via **stdout**, decrypts key **in memory**, loads it

The key file on disk **never leaves its encrypted state**.

---

## Directory Layout After Setup

```
/u001/data/as17/
├── conf.d/
│   └── ssl.conf              # SSL parameters (include'd by postgresql.conf)
├── pg_hba.conf               # Generated: hostssl enforcement
├── security/
│   ├── deploy_ssl.env              # Your site config (chmod 600)
│   ├── server.key            # ENCRYPTED private key
│   ├── .ssl_key_passphrase   # Passphrase for PostgreSQL startup
│   ├── read_passphrase.sh    # ssl_passphrase_command helper
│   ├── server_chained.crt    # Server certificate chain
│   ├── root.crt              # Root CA certificate
│   └── .backup-YYYYMMDD/     # Timestamped backups of overwritten files
```

---

## Environment Variables Reference

| Variable | Example | Description |
|----------|---------|-------------|
| `DATA_TOP` | `/u001/data/as17` | PostgreSQL data directory |
| `SECURITY_TOP` | `/u001/data/as17/security` | Where keys/certs live |
| `SYSTEM_USER` | `enterprisedb` | OS user running EPAS |
| `SYSTEM_GROUP` | `enterprisedb` | OS group |
| `SERVICE_NAME` | `edb-as-17` | systemd service name |
| `PRIMARY_PORT` | `5444` | EPAS listen port |
| `PRIMARY_HOST` | `192.168.1.11` | Primary node address |
| `STANDBY_HOST` | `192.168.1.12` | Standby node address |
| `SUBNET_CIDR` | `192.168.1.0/24` | Subnet for `hostssl` rules |

---

## Troubleshooting

### "Private key is NOT encrypted"
Your bundle contains an unencrypted key. `epas-ssl-setup.sh` requires encryption. Re-run `generate-selfsigned.sh` and set a passphrase.

### "Incorrect passphrase"
The passphrase you typed does not decrypt the key. If you forgot it, regenerate the bundle.

### Service fails to start after restart
1. Check journal: `journalctl -u edb-as-17 -n 50`
2. Check config syntax: `su - enterprisedb -c "pg_ctl -D /u001/data/as17 check"`
3. Check permissions: `ls -la /u001/data/as17/security/`
4. Restore from backup: `cp /u001/data/as17/security/.backup-*/pg_hba.conf /u001/data/as17/`

### SSL handshake fails from client
Ensure the client trusts `root.crt`:
```bash
psql "sslmode=verify-ca sslrootcert=/path/to/root.crt host=server1 ..."
```

---

## Certificate Renewal

1. Generate a new bundle (same SANs, new expiry).
2. Run `epas-ssl-setup.sh` again — it automatically backs up old files.
3. No need to distribute a new `root.crt` if you kept the same CA.

---

## Requirements

- `openssl` >= 1.1.1
- `systemctl`
- `bash` >= 4.2
- `ss` (iproute2) for post-restart verification
- Run as `root` or via `sudo`

---

## License

Internal use only. No warranty. Review before production deployment.
