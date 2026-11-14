# 03-patching — minor version patching

**No script here runs as root and none calls `dnf`.** The sysadmin installs the packages; the DBA does
everything else, using only the sudo whitelist `conf/sudoers.d/epas-automation` (start/stop of the
EPAS and EFM services, `efm cluster-status`).

## How a patch is done (one node at a time)

| Step | Who | What |
|---|---|---|
| 1 | DBA | `node-maintenance-stop.sh`: stops and disables the local EFM agent (EFM clusters), stops EPAS, notes the installed package version |
| 2 | **Sysadmin** | `dnf upgrade -y 'edb-as<EPAS_VERSION>*'` (e.g. `edb-as17*`; only that EPAS version's packages) |
| 3 | DBA | `node-maintenance-start.sh --patched`: refuses to start anything if the package version did not change; starts EPAS; runs `edb_sqlpatch` on a primary (not on a standby); then enables and starts EFM and waits for the cluster |

Without new packages (a plain reboot or OS patching) use `node-maintenance-start.sh` without `--patched`.
EFM clusters: patch the standbys first, the primary last, one node at a time. `edb_sqlpatch` runs only on the
primary; a standby gets the catalog changes by replication.

All scripts **require** a config: `--env <file>`, or `conf/site.env` in the repo (created with `make env`).
Each run prints the settings it will use, then asks **"Proceed? (y/N)"** when run from a terminal
(`--yes` skips the question; without a terminal they proceed anyway, but pass `--yes` in cron and Ansible so it is explicit).

| Script | Run as / where | Purpose |
|---|---|---|
| `node-maintenance-stop.sh` | **DBA** (`enterprisedb`), on the node | Take this node out of service before OS patching or a reboot: stop & disable EFM, list the IP addresses (`SITE="primary"` only), stop EPAS (it stays enabled) and confirm it is down |
| `node-maintenance-start.sh [--patched]` | **DBA** (`enterprisedb`), on the node | Bring it back: start EPAS, wait for it on `PRIMARY_PORT`, then enable & start EFM and wait for it to report the cluster. **EFM is not started if EPAS does not come up within 60 s.** |

The same two `node-maintenance-*` scripts are used at both sites, with or without EFM, for a minor patch or for OS patching;
`SITE` and `HA_TOOL` in `conf/site.env` decide what they do.

Settings used (`conf/site.env`): `EPAS_VERSION`, `EFM_VERSION`, `EFM_CLUSTER_NAME`, `SYSTEM_USER`, `PRIMARY_PORT`, `SRC_BINARY_DIR` (for `pg_isready`, `psql`, `edb_sqlpatch`), `VIP_INTERFACE`, `VIP_ADDRESS`, `HA_TOOL`, `SITE`. The `efm` command is taken from `/usr/edb/efm-<EFM_VERSION>/bin/efm` (or `EFM_BIN`).

## Unattended use and exit codes

Both scripts call `sudo -n`: a missing sudoers entry fails at once instead of waiting for a password. Pass `--yes`.

| Exit code | Meaning | What a playbook or person does |
|---|---|---|
| `0` | Done. For `node-maintenance-start.sh`: EPAS is up and EFM reports the cluster (or `HA_TOOL="none"`). | Go on to the next step or node |
| `1` | Refused or failed. The message says what was and was not stopped or started. | Stop and fix; the script is safe to run again |
| `2` | Only `node-maintenance-start.sh`: EPAS is running but EFM did not report the cluster in time. | **Stop. Do not touch the next node** until a person has looked: `efm cluster-status <cluster>` |

`EFM_WAIT_TRIES` and `EFM_WAIT_SECS` (default 12 and 5, so 60 seconds) set how long the start script waits for EFM.
Run `node-maintenance-stop.sh` a second time on an already stopped node (a retry after the sysadmin's `dnf`) and it keeps the first note of the package version.

## Clusters without EFM (`HA_TOOL="none"`)

Set `HA_TOOL="none"` in `conf/site.env` for a cluster that has no failover manager. Then:

| Script | With `HA_TOOL="none"` |
|---|---|
| `node-maintenance-stop.sh` | Skips the EFM steps and stops EPAS. It first checks that no EFM agent is running on the host and stops if one is: stopping EPAS under a running agent can cause a failover. |
| `node-maintenance-start.sh` | Starts EPAS, waits for it, skips the EFM steps. |

The default is `HA_TOOL="efm"`, so a config file without the setting behaves as before.

## When a stop fails

`node-maintenance-stop.sh` stops with an error, and writes no audit line, when EFM or EPAS cannot be
stopped or EPAS is still running afterwards. EPAS is never stopped if EFM could not be stopped
and disabled first. A stop of a service that is already stopped is not an error, so the script
can be run again.

Typical order: on each DR node `node-maintenance-stop.sh` → sysadmin patches → `node-maintenance-start.sh` (`--patched` after a package update), then the primary site the same way.

## The package-version note

`node-maintenance-stop.sh` writes the installed `edb-as<ver>-server` version to `<log directory>/patching/<host>_<service>.version`
(for example `/pglog/toolkit/patching/`). `node-maintenance-start.sh --patched` compares it with what is installed now and refuses to start
anything if it is the same, so a forgotten or failed `dnf` is caught before the database starts on old packages.
Best effort: if the note cannot be written, the stop script warns and `--patched` will refuse later (run without it if you are sure).
