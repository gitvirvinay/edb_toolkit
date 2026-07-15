# EDB Postgres Enterprise Lifecycle Toolkit

A comprehensive, production-grade automation suite for orchestrating **EDB Postgres Advanced Server (EPAS)** and **EDB Failover Manager (EFM)** environments.

## Repository Architecture

| Module | Purpose |
|--------|---------|
| `01-provisioning-engine/` | Day 1 base platform layouts, custom binary segregation, performance tracking preloads, and dynamic replica rebuilding |
| `02-security-hardening/` | Automated PKI/SSL validation, cipher string alignment, and secure HBA template generation |
| `03-lifecycle-patching/` | Controlled sequencing and rolling maintenance scripts designed to patch platforms without disrupting EFM quorums or causing split-brains |
| `04-major-upgrades/` | Multi-version data transformation engines utilizing parallel logical pipelines (pg_upgrade --link is NOT supported for major version jumps with TDE) |
| `05-high-availability-efm/` | Clustering & failsafe VIP routing, rolling EFM upgrades with explicit version safety checks |
| `06-backup-recovery/` | Pre-flight backup verification, pgBackRest validation, and prepatch snapshot automation |

## Security Notes

- **Never commit `.env` files or passphrase files.** Use a secrets manager (HashiCorp Vault, AWS Secrets Manager, or Azure Key Vault).
- The `deploy.env.example` file contains placeholder values -- replace `CHANGEME` markers before use.
- TDE passphrases should be injected at runtime, never hardcoded.
- For production TDE key management, integrate with a KMIP-compatible key store rather than file-based passphrases.
