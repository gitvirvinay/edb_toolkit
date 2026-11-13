# 03-patching — minor version patching

All scripts **require** a config: `--env <file>`, or `conf/site.env` in the repo (created with `make env`).
Each run prints the settings it will use, then asks **"Proceed? (y/N)"** when run from a terminal
(`--yes` skips the question; non-interactive runs such as Ansible/cron proceed without asking).

| Script | Run as / where | Purpose |
|---|---|---|
| `node-maintenance-stop.sh` | user with sudo, on the node | Take this node out of service before OS patching or a reboot: stop & disable EFM, list the IP addresses (`SITE="primary"` only), stop EPAS (it stays enabled) and confirm it is down |
| `node-maintenance-start.sh` | user with sudo, on the node | Bring it back: start EPAS, wait for it on `PRIMARY_PORT`, then enable & start EFM and wait for it to report the cluster. **EFM is not started if EPAS does not come up within 60 s.** |
| `epas-minor-update.sh [<version>]` | **root**, a node without EFM | Stop service, `dnf upgrade edb-as<version>-server*`, restart, run `edb_sqlpatch`. Version defaults to `EPAS_VERSION`. Refuses to run while an EFM agent is active on the host. |
| `epas-minor-update-efm.sh` | **root**, each EFM node in turn | VIP check → stop the **local** EFM agent only → stop EPAS → `dnf upgrade edb-as<EPAS_VERSION>*` → start EPAS (60 s safety stop) → start EFM → cluster & VIP check |

The same two `node-maintenance-*` scripts are used at both sites and with or without EFM;
`SITE` and `HA_TOOL` in `conf/site.env` decide what they do.

Settings used (`conf/site.env`): `EPAS_VERSION`, `EFM_VERSION`, `EFM_CLUSTER_NAME`, `SYSTEM_USER`, `PRIMARY_PORT`, `SRC_BINARY_DIR` (for `pg_isready`), `VIP_INTERFACE`, `VIP_ADDRESS`, `HA_TOOL`, `SITE`. The `efm` command is taken from `/usr/edb/efm-<EFM_VERSION>/bin/efm` (or `EFM_BIN`).

## Clusters without EFM (`HA_TOOL="none"`)

Set `HA_TOOL="none"` in `conf/site.env` for a cluster that has no failover manager. Then:

| Script | With `HA_TOOL="none"` |
|---|---|
| `node-maintenance-stop.sh` | Skips the EFM steps and stops EPAS. It first checks that no EFM agent is running on the host and stops if one is: stopping EPAS under a running agent can cause a failover. |
| `node-maintenance-start.sh` | Starts EPAS, waits for it, skips the EFM steps. |
| `epas-minor-update-efm.sh` | Stops at once and points to `epas-minor-update.sh`. |
| `epas-minor-update.sh` | The script for these clusters. It never touches EFM, and refuses to run if an EFM agent is active on the host. |

The default is `HA_TOOL="efm"`, so a config file without the setting behaves as before.

## When a stop fails

`node-maintenance-stop.sh` stops with an error, and writes no audit line, when EFM or EPAS cannot be
stopped or EPAS is still running afterwards. EPAS is never stopped if EFM could not be stopped
and disabled first. A stop of a service that is already stopped is not an error, so the script
can be run again.

Typical order: on each DR node `node-maintenance-stop.sh` → patch → `node-maintenance-start.sh`, then the primary site the same way.
