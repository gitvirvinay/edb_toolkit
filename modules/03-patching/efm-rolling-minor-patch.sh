#!/usr/bin/env bash
# efm-rolling-minor-patch.sh — patch one EFM cluster node:
# VIP check, stop EFM, stop EPAS, dnf upgrade, start EPAS, start EFM, check cluster & VIP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--yes]
Patches THIS EFM node only: VIP check, stop the local EFM agent, stop EPAS, dnf upgrade edb-as<EPAS_VERSION>*,
restart EPAS, restart EFM, verify. Run on one node at a time; the other nodes keep EFM running.
Must run as root. EFM is NOT restarted if EPAS does not come up within 60 s.
Settings: EPAS_VERSION, EFM_VERSION, EFM_CLUSTER_NAME, SYSTEM_USER, PRIMARY_PORT,
          VIP_INTERFACE (default eth0), VIP_ADDRESS (empty = skip VIP checks) — from conf/site.env (required).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required
require_root

VIP_INTERFACE="${VIP_INTERFACE:-eth0}"
VIP_ADDRESS="${VIP_ADDRESS:-}"
EFM="$(efm_bin)"
show_config EPAS_SERVICE EFM_SERVICE EFM_CLUSTER_NAME SYSTEM_USER PRIMARY_PORT VIP_INTERFACE VIP_ADDRESS EFM
confirm_or_exit "rolling minor patch on $(hostname -s): stop local ${EFM_SERVICE} and ${EPAS_SERVICE}, dnf upgrade edb-as${EPAS_VERSION}*, restart"

log_info "Starting EFM Rolling Upgrade Sequence"

# Phase 1: Pre-upgrade VIP validation
log_info "[Phase 1] Validating VIP interface configuration"
if [ -n "$VIP_ADDRESS" ]; then
    VIP_PRESENT=$(ip addr show "$VIP_INTERFACE" 2>/dev/null | grep -c "$VIP_ADDRESS" || echo "0")
    if [ "$VIP_PRESENT" -eq 0 ]; then
        log_warn "VIP ${VIP_ADDRESS} not found on ${VIP_INTERFACE}. Checking failover state..."
        sudo "$EFM" cluster-status "$EFM_CLUSTER_NAME" || true
        if [ -t 0 ]; then
            read -r -p "Continue despite missing VIP? (y/N): " CONTINUE
            [[ "$CONTINUE" =~ ^[Yy]$ ]] || die "Aborting rolling upgrade due to VIP anomaly."
        fi
    else
        log_info "VIP ${VIP_ADDRESS} confirmed on ${VIP_INTERFACE}"
    fi
else
    log_warn "VIP_ADDRESS not set. Skipping VIP interface check."
fi

log_info "[Phase 2] Stopping the local EFM agent only (other nodes keep monitoring)"
# Do NOT use 'efm stop-cluster' here: it stops EFM on every node of the cluster.
sudo systemctl stop "$EFM_SERVICE"
sleep 3

log_info "[Phase 3] Entering EPAS maintenance window"
sudo systemctl stop "$EPAS_SERVICE"

log_info "[Phase 4] Applying EPAS ${EPAS_VERSION} patchset updates"
# Only this EPAS version's packages; other installed versions (e.g. during an upgrade) are left alone.
dnf upgrade -y "edb-as${EPAS_VERSION}*"

log_info "[Phase 5] Restarting EPAS"
sudo systemctl start "$EPAS_SERVICE"
wait_for_epas 12 5 || die "EPAS did not accept connections on port ${PRIMARY_PORT} within 60s — EFM NOT restarted. Check: systemctl status ${EPAS_SERVICE}"

log_info "[Phase 6] Restarting EFM and validating cluster"
sudo systemctl start "$EFM_SERVICE"
sleep 5

for i in {1..12}; do
    CLUSTER_STATUS=$(sudo "$EFM" cluster-status "$EFM_CLUSTER_NAME" 2>/dev/null | grep -c "UP" || echo "0")
    if [ "$CLUSTER_STATUS" -ge 2 ]; then
        log_info "EFM cluster healthy with ${CLUSTER_STATUS} UP nodes"
        break
    fi
    log_warn "Waiting for EFM cluster stabilization... ($i/12)"
    sleep 5
done

if [ -n "$VIP_ADDRESS" ]; then
    VIP_PRESENT=$(ip addr show "$VIP_INTERFACE" 2>/dev/null | grep -c "$VIP_ADDRESS" || echo "0")
    if [ "$VIP_PRESENT" -eq 0 ]; then
        log_warn "VIP not present on this node after upgrade. Expected if node is Standby."
    else
        log_info "VIP confirmed active on this node after upgrade"
    fi
fi

log_audit "EFM rolling upgrade completed successfully on $(hostname -s) (${EPAS_SERVICE}, ${EFM_SERVICE})"
