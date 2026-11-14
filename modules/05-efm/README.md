# 05-efm — EDB Failover Manager

Settings come from `conf/site.env` (see the EFM block in `conf/site.env.example`).

| Script | Purpose |
|---|---|
| `efm-setup.sh --role primary\|standby\|witness [--cluster NAME] [--out DIR]` | **Run as the DBA.** Prepares the configuration of one EFM agent: builds `<cluster>.properties`, `<cluster>.nodes` (and the unit file for a cluster not named `efm`) in `<log directory>/efm/<cluster>/`, shows what differs from the installed files and prints the commands the **sysadmin** runs as root (`dnf install`, then `install` for each file). Run it again afterwards: "already installed" means the step is done. Asks each value with the config value as default; `--yes` uses the config as-is. Several clusters per node supported (unique ports are checked). |
| `efm-cluster-status.sh` | Cluster status plus a check that at least 2 nodes are UP (read-only). |
| `efm-reconfigure-after-upgrade.sh [--properties FILE] [--out FILE]` | After a major upgrade (04-upgrade). **Run as the DBA.** Builds a corrected copy of the properties file (new `SRC_BINARY_DIR/bin`, `DATA_TOP`, `PRIMARY_PORT`, `SERVICE_NAME`) in `<log directory>/efm/`, shows the changes and prints the two commands the **sysadmin** runs as root (backup, then `install` with the same owner/mode). Run it again afterwards: "already up to date" means the step is done. The real file is never edited by the DBA. |

## Setting up a cluster

```bash
# as the DBA (enterprisedb), on each node - the sysadmin has installed the EFM package first (dnf install -y edb-efm53)
modules/05-efm/efm-setup.sh --role primary        # on the primary
modules/05-efm/efm-setup.sh --role standby        # on the standby
modules/05-efm/efm-setup.sh --role witness        # on the witness (WITNESS_HOST)
```

The script never runs as root and never installs anything. It prints what the **sysadmin** must run (as root): the backup of an
existing file and one `install -o efm -g efm -m 600 <staged file> /etc/edb/efm-<ver>/<file>` per file (plus the unit file and
`systemctl daemon-reload` for a cluster not named `efm`), then the firewall commands and `efm allow-node` (not in the DBA's sudo whitelist).
The DBA starts the agent with `sudo systemctl enable <unit>` and `sudo systemctl start <unit>`, which the whitelist allows for `edb-efm-<ver>`.
The removed options `--no-install` and `--start` stop with a message saying so.

Password: put it in `EFMPASS` or type it when asked; the script runs
`efm encrypt <cluster> --from-env` and writes `db.password.encrypted` into the staged file (never printed). If `efm encrypt` does not work for the DBA, it warns and tells the sysadmin or the `efm` user to run it. On a re-run without a password the
previous encrypted value is kept. The password is tied to the cluster name, so encrypt it again if you rename the cluster.

What it builds (EDB's documented layout; the sysadmin installs these into `/etc`):
- `/etc/edb/efm-<ver>/<cluster>.properties` from the package template `efm.properties.in` (the plan backs an existing file up
  as `.bak.<timestamp>`), with `bind.address`, `admin.port`, `is.witness`, `db.*`, `auto.allow.hosts=false`,
  `stable.nodes.file=true`, plus `ping.server.ip`, `user.email` and the virtual IP when set in the config.
- `/etc/edb/efm-<ver>/<cluster>.nodes` with all nodes.
- Cluster named `efm`: the packaged `edb-efm-<ver>.service` is used as shipped. Any other name: the packaged unit is
  copied to `/etc/systemd/system/efm-<cluster>.service` with only `Environment=CLUSTER=` and `PIDFile=` changed.
  Set `EFM_SERVICE="efm-<cluster>"` in the config so 03-patching controls the right agent (the script warns).

Start order: the primary's agent first; because `auto.allow.hosts=false`, the sysadmin (root or the `efm` user) runs `efm allow-node <cluster> <address>`
there for the other nodes, then the DBA starts them. The script prints the exact commands (firewall, pg_hba, allow-node).

Two clusters on one node (e.g. EPAS 15 and 17 during an upgrade): use a second config file with its own
`EFM_BIND_PORT`, `EFM_ADMIN_PORT`, `PRIMARY_PORT` and run with `--env that.env --cluster efm15`.
