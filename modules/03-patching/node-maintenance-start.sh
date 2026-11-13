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
# The counterpart of node-maintenance-stop.sh. Safe to run again.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes]
Brings this node back after maintenance: starts EPAS, waits for it on PRIMARY_PORT, then enables
and starts EFM and waits for it to report the cluster. EFM is NOT started if EPAS does not come
up within 60 s.
Settings: EPAS_VERSION, EFM_VERSION, EFM_CLUSTER_NAME, SYSTEM_USER, PRIMARY_PORT, HA_TOOL, SITE
          - from conf/site.env (required).
HA_TOOL=none: EPAS is started and checked; the EFM steps are skipped.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required

NODE="$(hostname -s) (${SITE} site)"
if [ "$HA_TOOL" = "efm" ]; then
    EFM="$(efm_bin)"
    show_config EPAS_SERVICE SITE HA_TOOL EFM_SERVICE EFM_CLUSTER_NAME SYSTEM_USER PRIMARY_PORT EFM
    confirm_or_exit "start ${EPAS_SERVICE}, then enable and start ${EFM_SERVICE} on ${NODE}"
else
    show_config EPAS_SERVICE SITE HA_TOOL SYSTEM_USER PRIMARY_PORT
    confirm_or_exit "start ${EPAS_SERVICE} on ${NODE} (HA_TOOL=none: no EFM steps)"
fi

log_info "Bringing ${NODE} back into service"
sudo systemctl start "$EPAS_SERVICE" \
    || die "Could not start ${EPAS_SERVICE} - EFM NOT started. Check: sudo systemctl status ${EPAS_SERVICE}"

wait_for_epas 12 5 || die "EPAS did not accept connections on port ${PRIMARY_PORT} within 60s — EFM NOT started. Check: sudo systemctl status ${EPAS_SERVICE}"

if [ "$HA_TOOL" != "efm" ]; then
    log_info "HA_TOOL=none: this cluster has no failover manager - EFM steps skipped"
    log_audit "Node back in service after maintenance: ${NODE}, ${EPAS_SERVICE}, no EFM"
    exit 0
fi

sudo systemctl enable "$EFM_SERVICE" \
    || die "EPAS is running, but ${EFM_SERVICE} could not be enabled - this node is NOT back in the EFM cluster. Check: sudo systemctl status ${EFM_SERVICE}"
sudo systemctl start "$EFM_SERVICE" \
    || die "EPAS is running, but ${EFM_SERVICE} could not be started - this node is NOT back in the EFM cluster. Check: sudo systemctl status ${EFM_SERVICE}"

log_info "Waiting for EFM to report the cluster..."
for i in {1..12}; do
    if sudo "$EFM" cluster-status "$EFM_CLUSTER_NAME" &>/dev/null; then
        log_info "EFM cluster status: healthy"
        log_audit "Node back in service after maintenance: ${NODE}, ${EPAS_SERVICE}, ${EFM_SERVICE}"
        exit 0
    fi
    log_warn "Waiting for EFM to stabilize... ($i/12)"
    sleep 5
done
log_warn "EFM status check timed out. Verify manually with: sudo ${EFM} cluster-status ${EFM_CLUSTER_NAME}"
log_audit "Node started after maintenance, EFM status NOT confirmed: ${NODE}, ${EPAS_SERVICE}, ${EFM_SERVICE}"
