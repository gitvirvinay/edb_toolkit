#!/usr/bin/env bash
# patch-primary-shutdown.sh — isolate a primary-site node before OS/EPAS patching:
# stop & disable EFM, show the node's VIPs, stop EPAS (it stays enabled).
# Stops with an error, and writes no audit line, if EFM or EPAS cannot be stopped.
# EPAS stays ENABLED: it starts by itself after the reboot (it is not the HA brain). EFM is disabled, so after a
# reboot no agent joins the cluster before the node has been checked - patch-*-startup.sh enables it again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes]
Stops and disables EFM, then stops EPAS (left enabled), on this primary-site node (run before patching).
Settings: EPAS_VERSION/SERVICE_NAME, EFM_VERSION, HA_TOOL — from conf/site.env (required).
HA_TOOL=none: the EFM steps are skipped; stops if an EFM agent is running on this host after all.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required
if [ "$HA_TOOL" = "efm" ]; then
    show_config EPAS_VERSION EPAS_SERVICE HA_TOOL EFM_SERVICE
    confirm_or_exit "stop and disable ${EFM_SERVICE}, then stop ${EPAS_SERVICE} on $(hostname -s)"
else
    show_config EPAS_VERSION EPAS_SERVICE HA_TOOL
    require_no_efm_agent                     # HA_TOOL=none must be true before EPAS is stopped
    confirm_or_exit "stop ${EPAS_SERVICE} on $(hostname -s) (HA_TOOL=none: no EFM steps)"
fi

log_info "Isolating Primary Node Infrastructure"
if [ "$HA_TOOL" = "efm" ]; then
    # A failed stop is never ignored here: with the agent still running, stopping EPAS below
    # would look like a database failure to EFM and could cause a failover.
    sudo systemctl stop "$EFM_SERVICE" \
        || die "Could not stop ${EFM_SERVICE}. EPAS was NOT stopped and nothing else was changed. Check: sudo systemctl status ${EFM_SERVICE}"
    sudo systemctl disable "$EFM_SERVICE" \
        || die "${EFM_SERVICE} is stopped but could not be disabled (it would start again after a reboot). EPAS was NOT stopped. Check: sudo systemctl status ${EFM_SERVICE}"
else
    log_info "HA_TOOL=none: this cluster has no failover manager - EFM steps skipped"
fi

log_info "Releasing Cluster VIP networks..."
ip addr show | grep -E "inet .* scope global" || true

if [ "$HA_TOOL" = "efm" ]; then UNDO_HINT=" ${EFM_SERVICE} is already stopped and disabled; the startup script in this folder brings the node back."; else UNDO_HINT=""; fi
sudo systemctl stop "$EPAS_SERVICE" \
    || die "Could not stop ${EPAS_SERVICE} - this node is NOT ready for maintenance.${UNDO_HINT} Check: sudo systemctl status ${EPAS_SERVICE}"
# Believe the service state, not the exit code of the stop: only a stopped database is ready.
if systemctl is-active --quiet "$EPAS_SERVICE"; then
    die "${EPAS_SERVICE} is still running after the stop - this node is NOT ready for maintenance.${UNDO_HINT} Check: sudo systemctl status ${EPAS_SERVICE}"
fi
log_info "${EPAS_SERVICE} is stopped"
if [ "$HA_TOOL" = "efm" ]; then HA_NOTE="$EFM_SERVICE"; else HA_NOTE="no EFM"; fi
log_audit "Primary node isolated cleanly for system level host maintenance (${EPAS_SERVICE}, ${HA_NOTE})"
