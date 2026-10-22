# EDB Postgres Enterprise Lifecycle Toolkit

Production automation for **EDB Postgres Advanced Server (EPAS)** and **EDB Failover Manager (EFM)**: build, SSL, patching, major upgrades, HA, backup, tuning and TDE.

## Layout

```
conf/                 shared configuration (one place for versions, paths, hosts)
  site.env.example      → copy to conf/site.env   (git-ignored) — used by every module
  tde.env.example       → copy to conf/tde.env    (git-ignored) — loads site.env + Thales/KMIP
  sudoers.d/            sudoers rules: automation, deployer, EPAS 14→17 upgrade
lib/common.sh         shared start-up: --env handling, config loading, settings summary (sources lib/logger.sh)
lib/logger.sh         central syslog/audit/file logger
modules/
  01-provision/       Day-1 build (/u001 layout or symlink variant), primary prep, standby rebuild, env generator
  02-ssl/             SSL/TLS setup, self-signed single/SAN bundles, ssl.conf migration, tests/
  03-patching/        Minor patching: primary_site/ & dr_site/ sequences, single-node update, EFM rolling patch
  04-upgrade/         Major upgrades: pg_upgrade (copy/link, TDE-aware) and pg_dump/pg_restore paths
  05-efm/             EFM cluster setup (interactive / multi-cluster), status, reconfigure after upgrade
  06-backup/          pgBackRest validation, pre-patch snapshot
  07-tuning/          Kernel HugePages/memory tuning, shared_buffers planning, verification, sql/ monitoring
  08-tde/             TDE with Thales CipherTrust (KMIP): new setup, openssl-passphrase → Thales migration
tools/                get-edb-inventory.sh — what EDB software/config is on this host
docs/                 package install recommendation, multi-day tuning audit procedure
tests/lint.sh         bash -n + CRLF check (+ shellcheck); run by CI (.github/workflows/lint.yml)
```

Each module has its own `README.md` with the scripts, who runs them and in which order.

## Quick start

```bash
make env                        # creates conf/site.env and conf/tde.env from the templates
vi conf/site.env                # versions, paths, hosts — or: modules/01-provision/generate-env.sh conf/site.env
make lint                       # syntax/line-ending check before copying to servers
sudo modules/01-provision/epas-base-build.sh conf/site.env
sudo modules/02-ssl/epas-ssl-setup.sh --env conf/site.env -b /tmp/bundle.pem
```

## How scripts find their settings

Scripts migrated to `lib/common.sh` (so far: 05 `efm-cluster-status.sh`, 06 both scripts, 07 `dba-epas-verify.sh`) all behave the same way:

1. `--env <file>`, `--env=<file>` or a first argument ending in `.env` — that file is used.
2. Otherwise `conf/site.env` in this repo is loaded automatically.
3. Otherwise: change-making scripts stop with a message; read-only scripts warn and use built-in defaults.

Every run prints the config file and the key values it will use (passwords masked) before doing anything.
Service names come from `EPAS_VERSION` / `EFM_VERSION` (e.g. `edb-as-${EPAS_VERSION}`), so a version change is a one-line edit in `conf/site.env`.

## Security notes

- Never commit real env files or passphrases — `conf/site.env`, `conf/tde.env` are git-ignored; templates hold placeholders only.
- Inject secrets at runtime (`export TDE_PASSPHRASE=…`, `THALES_PASS`, `OLD_TDE_PASSPHRASE`) or from a vault (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault).
- For production TDE key management use a KMIP key store (module 08) rather than file-based passphrases.
- `.gitattributes` forces LF line endings for `*.sh`, `*.sql` and env templates — CRLF breaks bash.
