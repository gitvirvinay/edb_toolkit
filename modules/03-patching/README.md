# 03-patching — minor version patching

All scripts **require** a config: `--env <file>`, or `conf/site.env` in the repo (created with `make env`).
Each run prints the settings it will use, then asks **"Proceed? (y/N)"** when run from a terminal
(`--yes` skips the question; non-interactive runs such as Ansible/cron proceed without asking).

| Script | Run as / where | Purpose |
|---|---|---|
| `primary_site/patch-primary-shutdown.sh` | user with sudo, each primary-site node | Stop & disable EFM, show VIPs, stop EPAS (it stays enabled) before patching |
| `primary_site/patch-primary-startup.sh` | user with sudo, each primary-site node | Start EPAS, wait for it on `PRIMARY_PORT`, then start EFM and check cluster status. **EFM is not started if EPAS does not come up within 60 s.** |
| `dr_site/patch-dr-shutdown.sh` | user with sudo, each DR node | Stop & disable EFM, then EPAS |
| `dr_site/patch-dr-startup.sh` | user with sudo, each DR node | Start EPAS, wait for it, then start EFM (same 60 s safety stop) |
| `epas-minor-patch-update.sh [<version>]` | **root**, single node | Stop service, `dnf upgrade edb-as<version>-server*`, restart, run `edb_sqlpatch`. Version defaults to `EPAS_VERSION`. |
| `efm-rolling-minor-patch.sh` | **root**, each EFM node in turn | VIP check → stop the **local** EFM agent only → stop EPAS → `dnf upgrade edb-as<EPAS_VERSION>*` → start EPAS (60 s safety stop) → start EFM → cluster & VIP check |

Settings used (`conf/site.env`): `EPAS_VERSION`, `EFM_VERSION`, `EFM_CLUSTER_NAME`, `SYSTEM_USER`, `PRIMARY_PORT`, `SRC_BINARY_DIR` (for `pg_isready`), `VIP_INTERFACE`, `VIP_ADDRESS`, `HA_TOOL`. The `efm` command is taken from `/usr/edb/efm-<EFM_VERSION>/bin/efm` (or `EFM_BIN`).

## Clusters without EFM (`HA_TOOL="none"`)

Set `HA_TOOL="none"` in `conf/site.env` for a cluster that has no failover manager. Then:

| Script | With `HA_TOOL="none"` |
|---|---|
| the two `*-shutdown.sh` scripts | Skip the EFM steps and stop EPAS. They first check that no EFM agent is running on the host and stop if one is: stopping EPAS under a running agent can cause a failover. |
| the two `*-startup.sh` scripts | Start EPAS, wait for it, skip the EFM steps. |
| `efm-rolling-minor-patch.sh` | Stops at once and points to `epas-minor-patch-update.sh`. |
| `epas-minor-patch-update.sh` | The script for these clusters. It never touches EFM, and refuses to run if an EFM agent is active on the host. |

The default is `HA_TOOL="efm"`, so a config file without the setting behaves as before.

## When a stop fails

The shutdown scripts stop with an error, and write no audit line, when EFM or EPAS cannot be
stopped or EPAS is still running afterwards. EPAS is never stopped if EFM could not be stopped
and disabled first. A stop of a service that is already stopped is not an error, so the scripts
can be run again.

Typical order: DR site shutdown → patch → DR startup, then the primary site the same way.
