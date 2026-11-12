#!/usr/bin/env bash
# patch-primary-startup.sh — bring a primary-site node back after patching:
# start EPAS, wait until it accepts connections, then enable & start EFM and check the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes]
Starts EPAS, waits for it on PRIMARY_PORT, then enables and starts EFM and checks cluster status.
EFM is NOT started if EPAS does not come up within 60 s.
Settings: EPAS_VERSION, EFM_VERSION, EFM_CLUSTER_NAME, SYSTEM_USER, PRIMARY_PORT, HA_TOOL — from conf/site.env (required).
HA_TOOL=none: EPAS is started and checked; the EFM steps are skipped.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required
if [ "$HA_TOOL" = "efm" ]; then
    EFM="$(efm_bin)"
    show_config EPAS_SERVICE HA_TOOL EFM_SERVICE EFM_CLUSTER_NAME SYSTEM_USER PRIMARY_PORT EFM
    confirm_or_exit "start ${EPAS_SERVICE}, then enable and start ${EFM_SERVICE} on $(hostname -s)"
else
    show_config EPAS_SERVICE HA_TOOL SYSTEM_USER PRIMARY_PORT
    confirm_or_exit "start ${EPAS_SERVICE} on $(hostname -s) (HA_TOOL=none: no EFM steps)"
fi

log_info "Reconnecting Primary Node Infrastructure"
sudo systemctl start "$EPAS_SERVICE"

wait_for_epas 12 5 || die "EPAS did not accept connections on port ${PRIMARY_PORT} within 60s — EFM NOT started. Check: sudo systemctl status ${EPAS_SERVICE}"

if [ "$HA_TOOL" != "efm" ]; then
    log_info "HA_TOOL=none: this cluster has no failover manager - EFM steps skipped"
    log_audit "Primary node reconnected after maintenance (${EPAS_SERVICE}, no EFM)"
    exit 0
fi

sudo systemctl enable "$EFM_SERVICE"
sudo systemctl start "$EFM_SERVICE"

log_info "Validating EFM clustering framework attachment..."
for i in {1..12}; do
    if sudo "$EFM" cluster-status "$EFM_CLUSTER_NAME" &>/dev/null; then
        log_info "EFM cluster status: healthy"
        log_audit "Primary node reconnected after maintenance (${EPAS_SERVICE}, ${EFM_SERVICE})"
        exit 0
    fi
    log_warn "Waiting for EFM to stabilize... ($i/12)"
    sleep 5
done
log_warn "EFM status check timed out. Verify manually with: sudo ${EFM} cluster-status ${EFM_CLUSTER_NAME}"
