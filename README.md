# EDB Postgres Enterprise Lifecycle Toolkit

Shell scripts for **EDB Postgres Advanced Server (EPAS)** and **EDB Failover Manager (EFM)**: build, SSL, patching, major upgrades, HA, backups, restore tests, tuning and TDE.

**Status:** written and unit-tested (`make test`); **not yet run on a real EPAS server**. Try it on DEV first. What changed in each version: [CHANGELOG.md](CHANGELOG.md).

## Start here: which document for which job

| I want to... | Read |
|---|---|
| Understand how the toolkit fits together | [Beginner's Guide](edb_toolkit%20%E2%80%94%20Beginner's%20Operating%20Guide.md), section 0 |
| See who does what, sysadmin or DBA | [docs/who-runs-what.md](docs/who-runs-what.md) |
| Get the toolkit onto a server | Guide, section 1 (three ways: Git, a bundle file, or pasted text) |
| Build a new cluster | Guide, section 2; [01-provision](modules/01-provision/README.md) |
| Bring an existing server under the toolkit | Guide, section 3 |
| Patch a node | [03-patching](modules/03-patching/README.md) |
| Back up, archive WAL, test a restore | [06-backup](modules/06-backup/README.md) |
| Upgrade to a new major version | [04-upgrade](modules/04-upgrade/README.md), [EFM steps](docs/epas-major-upgrade-efm.md), [rehearsal sheet](docs/epas-upgrade-rehearsal.md) |
| Set up or check EFM | [05-efm](modules/05-efm/README.md) |
| Set up SSL, TDE or kernel tuning | [02-ssl](modules/02-ssl/README.md), [08-tde](modules/08-tde/README.md), [07-tuning](modules/07-tuning/README.md) |
| Run jobs with no person present (Ansible, cron) | [docs/ansible-readiness.md](docs/ansible-readiness.md) |
| Understand why it is built this way | [docs/v2-design.md](docs/v2-design.md) (historical) |

## Quick start: a new server

Who runs each step is in brackets. The sysadmin does the root work, the DBA does the rest as `enterprisedb`.

```bash
# on the laptop: make the config
make env                  # creates conf/site.env and conf/tde.env from the templates (git-ignored)
vi conf/site.env          # versions, paths, hosts; or run modules/01-provision/generate-site-env.sh on an existing server

# on the server
sudo tools/install.sh                                                     # [sysadmin] puts the toolkit in /opt/dba/edb_toolkit
sudo /opt/dba/edb_toolkit/modules/01-provision/epas-base-build-root.sh    # [sysadmin] packages, folders, systemd
/opt/dba/edb_toolkit/modules/01-provision/epas-base-build-db.sh --tag SIT # [DBA] TDE passphrase file, initdb, config, registry
sudo systemctl start edb-as-17                                            # [DBA] allowed by the sudoers whitelist
```

SSL comes next, run by the DBA: `modules/02-ssl/epas-ssl-setup.sh -b <bundle.pem>`. The Beginner's Guide walks through every step with the output you should see.

## Rules that are the same in every script

- **Settings:** `--env <file>` picks the config file; without it a script uses `conf/site.env` in the toolkit. A script that changes something stops if it finds no config; a read-only one warns and uses defaults.
- **Before it acts:** every script prints the config file and the key values it will use (passwords masked), then asks `Proceed? (y/N)` on a terminal. `--yes` skips the question; use it in cron and Ansible.
- **Help:** `--help` works on every script.
- **Exit codes:** `0` = done, `1` = refused or failed, `2` = done but not confirmed (see `docs/ansible-readiness.md`).
- **Logs:** one file per run in `<LOG_MOUNT>/toolkit`, with an `[AUDIT]` line for every change.
- **Service names** come from `EPAS_VERSION` and `EFM_VERSION` (for example `edb-as-17`), so a version change is a one-line edit in `conf/site.env`.
- **Becoming `enterprisedb`:** `sudo -iu enterprisedb` in these documents and in script messages means "become the database user", however your site allows it. It is **not** in the toolkit's sudo whitelist and no script runs it for you.

## What is in the folders

```
conf/        site.env.example and tde.env.example (copy to site.env and tde.env, git-ignored);
             sudoers.d/ holds the DBA's sudo whitelist (epas-automation) and an EPAS 14 to 17 upgrade sample
lib/         shared code: common.sh (settings, prompts, helpers), logger.sh, epas-detect.sh, epas-layout.sh, epas-ssl.sh, epas-tde.sh
modules/
  01-provision/   build a cluster, prepare a primary, rebuild a standby, write site.env
  02-ssl/         SSL setup, self-signed certificates, ssl.conf migration, certificate check
  03-patching/    take a node out of service and bring it back (EFM or not, primary or DR site)
  04-upgrade/     major upgrades with pg_upgrade (TDE-aware) or pg_dump/pg_restore, post-upgrade backup
  05-efm/         EFM setup and reconfiguration (prints the root steps for the sysadmin), cluster status
  06-backup/      pg_basebackup, WAL archiving, restore test, pgBackRest checks, pre-patch snapshot
  07-tuning/      HugePages and kernel settings, shared_buffers planning, checks, monitoring SQL
  08-tde/         TDE with Thales CipherTrust (KMIP): new setup, openssl-to-Thales migration
tools/       install.sh (install into /opt/dba), epastab.sh (cluster registry), epasenv.sh and pg_bashrc.txt (DBA shell),
             get-edb-inventory.sh and list_epas_instances.sh (read-only reports), epas_full_uninstall.sh,
             make-bundle.sh and make-paste-kit.sh (package the toolkit for servers without Git)
docs/        who-runs-what, ansible-readiness, upgrade runbooks, package install advice, tuning audit, onboarding form
tests/       unit tests and tests/lint.sh; CI runs them on every push (.github/workflows/lint.yml)
```

Each module has its own `README.md` with its scripts, who runs them and in what order.

## Security notes

- Never commit real env files or passphrases. `conf/site.env` and `conf/tde.env` are git-ignored; the templates hold placeholders only.
- Give secrets to a script at run time (`export TDE_PASSPHRASE=...`, `THALES_PASS`, `OLD_TDE_PASSPHRASE`) or from a vault.
- The TDE passphrase lives on the host only in `/etc/edb/tde/<cluster>.pass` (owner `enterprisedb`, mode 0400). `postgresql.conf` stores just the `-pass file:` path. Keep a second copy in your vault: a standalone database has only this one.
- For production TDE key management, plan to move to a KMIP key store (module 08) instead of file-based passphrases.
- `.gitattributes` forces LF line endings for `*.sh`, `*.sql` and env templates, because CRLF breaks bash.
