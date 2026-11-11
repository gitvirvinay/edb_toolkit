# 05-efm — EDB Failover Manager

Settings come from `conf/site.env` (see the EFM block in `conf/site.env.example`).

| Script | Purpose |
|---|---|
| `efm-setup.sh --role primary\|standby\|witness [--cluster NAME] [--no-install] [--start]` | Install and configure one EFM agent. Run on every node. Asks each value with the config value as default; `--yes` uses the config as-is. Several clusters per node supported (unique ports are checked). |
| `efm-cluster-status.sh` | Cluster status plus a check that at least 2 nodes are UP (read-only). |
| `efm-reconfigure-after-upgrade.sh [--properties FILE]` | After a major upgrade (04-upgrade): points the agent at the new `SRC_BINARY_DIR/bin`, `DATA_TOP`, `PRIMARY_PORT`, `SERVICE_NAME`; backs up the file and shows the changes. |

## Setting up a cluster

```bash
sudo modules/05-efm/efm-setup.sh --role primary        # on the primary
sudo modules/05-efm/efm-setup.sh --role standby        # on the standby
sudo modules/05-efm/efm-setup.sh --role witness        # on the witness (WITNESS_HOST)
```

Password: put it in `EFMPASS` (`EFMPASS='...' sudo -E ...`) or type it when asked; the script runs
`efm encrypt <cluster> --from-env` and writes `db.password.encrypted`. On a re-run without a password the
previous encrypted value is kept. The password is tied to the cluster name, so encrypt it again if you rename the cluster.

What it writes (EDB's documented layout):
- `/etc/edb/efm-<ver>/<cluster>.properties` from the package template `efm.properties.in` (existing file backed up
  as `.bak.<timestamp>`), with `bind.address`, `admin.port`, `is.witness`, `db.*`, `auto.allow.hosts=false`,
  `stable.nodes.file=true`, plus `ping.server.ip`, `user.email` and the virtual IP when set in the config.
- `/etc/edb/efm-<ver>/<cluster>.nodes` with all nodes.
- Cluster named `efm`: the packaged `edb-efm-<ver>.service` is used as shipped. Any other name: the packaged unit is
  copied to `/etc/systemd/system/efm-<cluster>.service` with only `Environment=CLUSTER=` and `PIDFile=` changed.
  Set `EFM_SERVICE="efm-<cluster>"` in the config so 03-patching controls the right agent (the script warns).

Start order: the primary's agent first; because `auto.allow.hosts=false`, run `efm allow-node <cluster> <address>`
there for the other nodes, then start them. The script prints the exact commands (firewall, pg_hba, allow-node).

Two clusters on one node (e.g. EPAS 15 and 17 during an upgrade): use a second config file with its own
`EFM_BIND_PORT`, `EFM_ADMIN_PORT`, `PRIMARY_PORT` and run with `--env that.env --cluster efm15`.
