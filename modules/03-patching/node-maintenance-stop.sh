#!/usr/bin/env bash
# =============================================================================
# node-maintenance-stop.sh - take THIS node out of service before OS patching or a reboot.
#
#   HA_TOOL=efm    stop and disable the EFM agent, then stop EPAS
#   HA_TOOL=none   stop EPAS only; refused if an EFM agent is running on this host after all
#   SITE=primary   also lists this node's IP addresses, so you can see where the VIP is
#   SITE=dr        no address list (a DR node never holds the VIP)
#
# EPAS stays ENABLED: it starts by itself after the reboot (it is not the HA brain). EFM is
# disabled, so after a reboot no agent joins the cluster before the node has been checked -
# node-maintenance-start.sh enables it again.
# Once EPAS is stopped it notes the installed edb-as<ver>-server package version, so that
# node-maintenance-start.sh --patched can check that the sysadmin's dnf really changed it.
# Stops with an error, and writes no audit line, if EFM or EPAS cannot be stopped.
# One node at a time. Bring the node back with node-maintenance-start.sh.
#
# Unattended use (Ansible, cron): pass --yes. sudo is called with -n, so a missing sudoers entry fails
# at once instead of waiting for a password. Exit codes: 0 = node out of service; 1 = refused or failed
# (the message says what was and was not stopped). Run again after a failure: stopping what is already
# stopped is harmless, and an earlier note of the package version is kept (see below).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes]
Takes this node out of service before OS patching or a reboot: stops and disables EFM, then
stops EPAS (left enabled). Bring it back with node-maintenance-start.sh.
Settings: EPAS_VERSION/SERVICE_NAME, EFM_VERSION, HA_TOOL, SITE - from conf/site.env (required).
HA_TOOL=none: the EFM steps are skipped; stops if an EFM agent is running on this host after all.
SITE=primary: also lists this node's IP addresses (where is the VIP?). SITE=dr: no list.
Unattended: pass --yes. Exit codes: 0 = out of service; 1 = refused or failed. Safe to run again.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required

NODE="$(hostname -s) (${SITE} site)"
if [ "$HA_TOOL" = "efm" ]; then
    show_config EPAS_VERSION EPAS_SERVICE SITE HA_TOOL EFM_SERVICE
    confirm_or_exit "stop and disable ${EFM_SERVICE}, then stop ${EPAS_SERVICE} on ${NODE}"
else
    show_config EPAS_VERSION EPAS_SERVICE SITE HA_TOOL
    require_no_efm_agent                     # HA_TOOL=none must be true before EPAS is stopped
    confirm_or_exit "stop ${EPAS_SERVICE} on ${NODE} (HA_TOOL=none: no EFM steps)"
fi

log_info "Taking ${NODE} out of service for maintenance"
if [ "$HA_TOOL" = "efm" ] && [ "$SITE" = "primary" ]; then vip_status; fi
if [ "$HA_TOOL" = "efm" ]; then
    # A failed stop is never ignored here: with the agent still running, stopping EPAS below
    # would look like a database failure to EFM and could cause a failover.
    sudo -n systemctl stop "$EFM_SERVICE" \
        || die "Could not stop ${EFM_SERVICE}. EPAS was NOT stopped and nothing else was changed. Check: sudo systemctl status ${EFM_SERVICE}"
    sudo -n systemctl disable "$EFM_SERVICE" \
        || die "${EFM_SERVICE} is stopped but could not be disabled (it would start again after a reboot). EPAS was NOT stopped. Check: sudo systemctl status ${EFM_SERVICE}"
    UNDO_HINT=" ${EFM_SERVICE} is already stopped and disabled; node-maintenance-start.sh brings the node back."
    HA_NOTE="$EFM_SERVICE"
else
    log_info "HA_TOOL=none: this cluster has no failover manager - EFM steps skipped"
    UNDO_HINT=""
    HA_NOTE="no EFM"
fi

if [ "$SITE" = "primary" ]; then
    log_info "IP addresses on this node now (check where the VIP is):"
    ip addr show | grep -E "inet .* scope global" || true     # information only; no match is not an error
fi

EPAS_WAS_RUNNING=1; systemctl is-active --quiet "$EPAS_SERVICE" || EPAS_WAS_RUNNING=0
sudo -n systemctl stop "$EPAS_SERVICE" \
    || die "Could not stop ${EPAS_SERVICE} - this node is NOT ready for maintenance.${UNDO_HINT} Check: sudo systemctl status ${EPAS_SERVICE}"
# Believe the service state, not the exit code of the stop: only a stopped database is ready.
if systemctl is-active --quiet "$EPAS_SERVICE"; then
    die "${EPAS_SERVICE} is still running after the stop - this node is NOT ready for maintenance.${UNDO_HINT} Check: sudo systemctl status ${EPAS_SERVICE}"
fi
log_info "${EPAS_SERVICE} is stopped"

# Note the package version now: the sysadmin's dnf comes next (best effort - it only helps the later check).
PRE_VER="$(epas_pkg_version)"; STATE_FILE="$(patch_state_file)"
if [ "$EPAS_WAS_RUNNING" = 0 ] && [ -n "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
    # Run a second time after the sysadmin's dnf (a retry): the first note is the one that proves the update.
    log_info "${EPAS_SERVICE} was already stopped: keeping the earlier note of the package version ($(head -n1 "$STATE_FILE"))"
elif [ -n "$PRE_VER" ] && [ -n "$STATE_FILE" ] \
   && { mkdir -p "$(dirname "$STATE_FILE")" && printf '%s\n' "$PRE_VER" > "$STATE_FILE"; } 2>/dev/null; then
    log_info "Installed edb-as${EPAS_VERSION}-server is ${PRE_VER} (noted for node-maintenance-start.sh --patched)"
else
    log_warn "Could not note the installed package version: node-maintenance-start.sh --patched will not be able to check that dnf ran."
fi
log_audit "Node stopped for maintenance: ${NODE}, ${EPAS_SERVICE}, ${HA_NOTE}"
