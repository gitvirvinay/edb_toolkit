# EPAS PostgreSQL In-Place SSL Setup & Hardening

This repository provides a streamlined, production-grade automation utility to configure and harden Transparent Data Encryption (TDE-compatible) SSL/TLS connection layers on EDB Postgres Advanced Server (EPAS) deployments. It implements a modular architectural pattern utilizing Postgres' `include_dir` configuration directive to cleanly separate security configurations from core database parameters.

## 📂 Repository Layout


epas_ssl/
├── README.md
├── epas-ssl-setup.sh
├── config.env.example
├── templates/
│   ├── ssl.conf.template
│   └── pg_hba.conf.template
└── tests/
    ├── preflight-check.sh     # Runs BEFORE engine restart (validates local cert files)
    └── verify-db-ssl.sh       # Runs AFTER engine restart (validates actual db engine state)

## Usage

cp config.env.example prod.env
## Modify prod.env accordinly and execute
./epas-ssl-setup.sh --env prod.env




## 🔍 Post-Deployment Verification

Once the database engine has been restarted by the script, log into your primary EPAS instance using `psql` to confirm that the connection and streaming replication channels are operating exclusively over SSL:

```sql
-- 1. Confirm the core engine has active SSL configuration
SHOW ssl;

-- 2. Verify all active streaming replication connections are encrypted
SELECT client_addr, ssl, ssl_version, ssl_cipher, ssl_client_dn 
FROM pg_stat_ssl 
JOIN pg_stat_replication ON pg_stat_ssl.pid = pg_stat_replication.pid;


### 🔑 Expected PEM Bundle Format

When selecting **Option 1** to process an existing deployment bundle, the script expects a single unified PEM file containing your private key and the complete certificate validation path ordered from the leaf to the root. Ensure your bundle matches this structural format:

```text
-----BEGIN RSA PRIVATE KEY-----
[Encrypted or Plaintext Server Private Key Material Goes Here]
-----END RSA PRIVATE KEY-----
-----BEGIN CERTIFICATE-----
[Primary Server/Leaf Certificate Block]
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
[Intermediate Certificate Block - Optional]
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
[Root CA Certificate Block]
-----END CERTIFICATE-----