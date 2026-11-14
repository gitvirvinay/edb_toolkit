#!/usr/bin/env bash
# =============================================================================
# node-maintenance-start.sh - bring THIS node back into service after OS patching or a reboot.
#
#   HA_TOOL=efm    start EPAS, wait until it accepts connections, then enable and start the
#                  EFM agent and wait for EFM to report the cluster (both sites)
#   HA_TOOL=none   start EPAS and wait until it accepts connections
#
# EFM is NOT started if EPAS does not come up within 60 s: an agent must never join the
# cluster on top of a database that is not running.
# --patched: after the sysadmin has installed new packages (dnf). Checks that the package version
#            changed (nothing is started if not), then runs edb_sqlpatch on a primary before EFM starts.
# The counterpart of node-maintenance-stop.sh. Safe to run again.
#
# Unattended use (Ansible, cron): pass --yes. sudo is called with -n, so a missing sudoers entry fails at
# once instead of waiting for a password. Exit codes:
#   0  node back in service, EFM reports the cluster (or HA_TOOL=none)
#   1  error: the message says what was not started
#   2  EPAS is running, but EFM did not confirm the cluster in time: a person must look before the
#      next node is touched (a playbook stops here instead of patching the next node)
# EFM_WAIT_TRIES / EFM_WAIT_SECS (default 12 x 5 s) set how long to wait for EFM.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes] [--patched]
Brings this node back after maintenance: starts EPAS, waits for it on PRIMARY_PORT, then enables
and starts EFM and waits for it to report the cluster. EFM is NOT started if EPAS does not come
up within 60 s.
Settings: EPAS_VERSION, EFM_VERSION, EFM_CLUSTER_NAME, SYSTEM_USER, PRIMARY_PORT, HA_TOOL, SITE
          - from conf/site.env (required).
HA_TOOL=none: EPAS is started and checked; the EFM steps are skipped.
--patched: the sysadmin has installed new EPAS packages (dnf) while the node was stopped. Checks that
  edb-as<ver>-server really changed since node-maintenance-stop.sh (if not, NOTHING is started), then
  starts EPAS, runs edb_sqlpatch if this node is a primary (a standby gets the changes by replication),
  and only then starts EFM. Without --patched nothing about packages is checked (plain reboot).
Unattended: pass --yes. Exit codes: 0 = node back in service and EFM reports the cluster (or HA_TOOL=none);
  1 = error, the message says what was not started; 2 = EPAS is running but EFM did not confirm the
  cluster in time - a person must look before the next node is touched.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
PATCHED=0
for _arg in "$@"; do
    case "$_arg" in -h|--help) usage ;; --patched) PATCHED=1 ;; *) die "Unknown option: ${_arg} (see --help)" ;; esac
done
load_env required
PATCH_NOTE=""
if [ "$PATCHED" = 1 ]; then PATCH_NOTE=" (--patched: check the packages changed, run edb_sqlpatch on a primary)"; fi

NODE="$(hostname -s) (${SITE} site)"
if [ "$HA_TOOL" = "efm" ]; then
    EFM="$(efm_bin)"
    show_config EPAS_SERVICE SITE HA_TOOL EFM_SERVICE EFM_CLUSTER_NAME SYSTEM_USER PRIMARY_PORT EFM
    confirm_or_exit "start ${EPAS_SERVICE}, then enable and start ${EFM_SERVICE} on ${NODE}${PATCH_NOTE}"
else
    show_config EPAS_SERVICE SITE HA_TOOL SYSTEM_USER PRIMARY_PORT
    confirm_or_exit "start ${EPAS_SERVICE} on ${NODE} (HA_TOOL=none: no EFM steps)${PATCH_NOTE}"
fi

if [ "$PATCHED" = 1 ]; then
    NOW_VER="$(epas_pkg_version)"; STATE_FILE="$(patch_state_file)"
    [ -n "$NOW_VER" ] || die "--patched: cannot read the installed edb-as${EPAS_VERSION}-server version (rpm -q failed). Nothing was started."
    { [ -n "$STATE_FILE" ] && [ -r "$STATE_FILE" ]; } \
        || die "--patched: no note of the package version from before patching (${STATE_FILE:-no log directory}). node-maintenance-stop.sh writes it when it stops the node. Nothing was started."
    PRE_VER="$(head -n1 "$STATE_FILE")"
    [ "$NOW_VER" != "$PRE_VER" ] \
        || die "--patched: edb-as${EPAS_VERSION}-server is still ${NOW_VER}, as when this node was stopped: the sysadmin's dnf has not run (or found nothing new). Nothing was started. Without new packages, run this script without --patched."
    log_info "Packages changed: ${PRE_VER} -> ${NOW_VER}"
fi

log_info "Bringing ${NODE} back into service"
sudo -n systemctl start "$EPAS_SERVICE" \
    || die "Could not start ${EPAS_SERVICE} - EFM NOT started. Check: sudo systemctl status ${EPAS_SERVICE}"

wait_for_epas 12 5 || die "EPAS did not accept connections on port ${PRIMARY_PORT} within 60s — EFM NOT started. Check: sudo systemctl status ${EPAS_SERVICE}"

if [ "$PATCHED" = 1 ]; then
    IN_RECOVERY="$(run_as_db_user "$(epas_cmd psql)" -X -At -p "$PRIMARY_PORT" -d postgres -c 'SELECT pg_is_in_recovery()')" \
        || die "Could not ask EPAS whether this node is a standby - edb_sqlpatch NOT run, EFM NOT started."
    if [ "$IN_RECOVERY" = "t" ]; then
        log_info "This node is a standby: edb_sqlpatch runs on the primary only; the catalog changes reach this node by replication"
    elif command -v "$(epas_cmd edb_sqlpatch)" >/dev/null 2>&1; then
        log_info "Running edb_sqlpatch (catalog adjustments after the package update)"
        run_as_db_user env PGPORT="$PRIMARY_PORT" "$(epas_cmd edb_sqlpatch)" -af \
            || die "edb_sqlpatch failed - EFM NOT started. Fix it first (see the output above), then run: $0 --patched"
    else
        log_warn "edb_sqlpatch not found for EPAS ${EPAS_VERSION}: step skipped. Check the EPAS release notes if this version needs it."
    fi
fi

if [ "$HA_TOOL" != "efm" ]; then
    log_info "HA_TOOL=none: this cluster has no failover manager - EFM steps skipped"
    log_audit "Node back in service after maintenance: ${NODE}, ${EPAS_SERVICE}, no EFM"
    exit 0
fi

sudo -n systemctl enable "$EFM_SERVICE" \
    || die "EPAS is running, but ${EFM_SERVICE} could not be enabled - this node is NOT back in the EFM cluster. Check: sudo systemctl status ${EFM_SERVICE}"
sudo -n systemctl start "$EFM_SERVICE" \
    || die "EPAS is running, but ${EFM_SERVICE} could not be started - this node is NOT back in the EFM cluster. Check: sudo systemctl status ${EFM_SERVICE}"

log_info "Waiting for EFM to report the cluster..."
EFM_WAIT_TRIES="${EFM_WAIT_TRIES:-12}"; EFM_WAIT_SECS="${EFM_WAIT_SECS:-5}"
i=1
while [ "$i" -le "$EFM_WAIT_TRIES" ]; do
    if sudo -n "$EFM" cluster-status "$EFM_CLUSTER_NAME" &>/dev/null; then
        log_info "EFM cluster status: healthy"
        vip_status
        log_audit "Node back in service after maintenance: ${NODE}, ${EPAS_SERVICE}, ${EFM_SERVICE}"
        exit 0
    fi
    log_warn "Waiting for EFM to stabilize... ($i/${EFM_WAIT_TRIES})"
    sleep "$EFM_WAIT_SECS"
    i=$((i + 1))
done
log_error "EPAS is running, but EFM did not report the cluster in time - this node is NOT confirmed back in the EFM cluster. Check: sudo ${EFM} cluster-status ${EFM_CLUSTER_NAME}"
log_audit "Node started after maintenance, EFM status NOT confirmed: ${NODE}, ${EPAS_SERVICE}, ${EFM_SERVICE}"
exit 2
