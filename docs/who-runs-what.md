# Who runs what: sysadmin (root) and DBA

The rule of the toolkit: **the sysadmin does the root work (packages, files in `/etc`, mounts, kernel settings, the sudoers file); the DBA does everything else as the database OS user (`enterprisedb`).** The DBA has no root and no `su` in any script. The only sudo the DBA has is the whitelist `conf/sudoers.d/epas-automation`:

- `systemctl start|stop|restart|reload` on `edb-as-15`, `-16`, `-17`, `-18` (short name and `.service`)
- `systemctl start|stop|restart|enable|disable` on `edb-efm-5.3`
- `efm cluster-status efm`, `pgbackrest`, `systemd-ask-password`

Where a root step sits in the middle of a DBA task, the DBA script **prepares and prints** the exact commands for the sysadmin, and can be run again afterwards to prove the step was done ("already installed" / "already up to date"). Nothing is run by a script on the sysadmin's behalf as someone else.

One-time per server: the sysadmin installs the whitelist: `sudo install -m 0440 conf/sudoers.d/epas-automation /etc/sudoers.d/epas-automation && sudo visudo -c`.

## By task

| Task | Sysadmin (root) | DBA (`enterprisedb`) |
|---|---|---|
| **Install the toolkit** | `tools/install.sh` (to `/opt/dba/edb_toolkit`) | |
| **Build a new server** | `01-provision/epas-base-build-root.sh` (packages, folders, systemd drop-in) | then `epas-base-build-db.sh --tag <ENV>` (TDE passphrase file, initdb, conf.d, registry) |
| **Kernel tuning** | `07-tuning/setup-epas-kernel.sh` (HugePages, sysctl) | `dba-epas-verify.sh`, `dba-resize-buffers.sh` (plans, then asks the sysadmin to re-run the kernel script) |
| **SSL** | one-time: folder and sudoers from the build | `02-ssl/epas-ssl-setup.sh`, `epas-ssl-relocate.sh`, `epas-migrate-ssl-conf.sh`, `check-cert.sh` |
| **Minor patch** (per node) | `dnf upgrade -y 'edb-as<ver>*'` | `03-patching/node-maintenance-stop.sh`, then (after the sysadmin) `node-maintenance-start.sh --patched` |
| **OS patch or reboot** (no new EPAS packages) | the OS patching / reboot | `node-maintenance-stop.sh`, then `node-maintenance-start.sh` |
| **Major upgrade** | installs the new EPAS packages before the window | `04-upgrade/epas-major-pgupgrade.sh` (or `epas-major-pgrestore.sh`), `epas-post-upgrade-backup.sh`; services through the whitelist |
| **EFM setup** | `dnf install -y edb-efm53`; installs the prepared files; firewall; `efm allow-node` | `05-efm/efm-setup.sh` (builds and compares, prints the sysadmin commands), then `sudo systemctl enable/start edb-efm-5.3` |
| **EFM after a major upgrade** | installs the prepared `efm.properties` (backup, then `install`) | `05-efm/efm-reconfigure-after-upgrade.sh` (builds it, then proves it), restarts the agent |
| **EFM status** | | `05-efm/efm-cluster-status.sh` |
| **Backups, WAL archiving, restore test** | | `06-backup/*` (`enable-wal-archiving.sh`, `take-basebackup.sh`, `restore-test.sh`, ...) |
| **Standby rebuild** | | `01-provision/epas-rebuild-standby.sh`, `epas-prep-primary.sh` |
| **Registry, inventory, listings** | `epastab.sh init` once per host | `epastab.sh` day to day, `list_epas_instances.sh`, `get-edb-inventory.sh` (less detail without root) |
| **Remove EPAS from a server** | `tools/epas_full_uninstall.sh` (asks for the host name first) | |

## The one exception today: TDE with Thales

`08-tde/tde-thales-setup.sh` and `tde-openssl-to-thales-migrate.sh` still run as root and use `sudo -u enterprisedb` inside the script. They belong to the Thales proof of concept and will be reworked on the same pattern (DBA prepares and checks, sysadmin does only the root steps) once the POC settles.

## Changing the rule

If a new script needs root, put the root part in its own `*-root.sh` or print it as commands for the sysadmin. Never call `dnf`, write under `/etc`, or `chown` from a script the DBA runs.
