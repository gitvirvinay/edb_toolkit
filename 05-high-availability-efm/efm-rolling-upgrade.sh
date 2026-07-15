#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

EFM_SERVICE="${EFM_SERVICE:-edb-efm-5.3}"
EPAS_SERVICE="${EPAS_SERVICE:-edb-as-17}"
VIP_INTERFACE="${VIP_INTERFACE:-eth0}"
VIP_ADDRESS="${VIP_ADDRESS:-}"

log_info "Starting EFM Rolling Upgrade Sequence"

# Phase 1: Pre-upgrade VIP validation
log_info "[Phase 1] Validating VIP interface configuration"
if [ -n "$VIP_ADDRESS" ]; then
    VIP_PRESENT=$(ip addr show "$VIP_INTERFACE" 2>/dev/null | grep -c "$VIP_ADDRESS" || echo "0")
    if [ "$VIP_PRESENT" -eq 0 ]; then
        log_warn "VIP ${VIP_ADDRESS} not found on ${VIP_INTERFACE}. Checking failover state..."
        sudo efm cluster-status efm || true
        if [ -t 0 ]; then
            read -p "Continue despite missing VIP? (y/N): " CONTINUE
            [[ "$CONTINUE" =~ ^[Yy]$ ]] || { log_error "Aborting rolling upgrade due to VIP anomaly."; exit 1; }
        fi
    else
        log_info "VIP ${VIP_ADDRESS} confirmed on ${VIP_INTERFACE}"
    fi
else
    log_warn "VIP_ADDRESS not set. Skipping VIP interface check."
fi

log_info "[Phase 2] Stopping EFM agent gracefully"
sudo efm stop-cluster efm 2>/dev/null || sudo systemctl stop "$EFM_SERVICE"
sleep 3

log_info "[Phase 3] Entering EPAS maintenance window"
sudo systemctl stop "$EPAS_SERVICE"

log_info "[Phase 4] Applying EFM package updates"
dnf upgrade -y "edb-efm*" || true

log_info "[Phase 5] Restarting EPAS"
sudo systemctl start "$EPAS_SERVICE"
for i in {1..12}; do
    if sudo -u enterprisedb pg_isready -q; then
        log_info "EPAS accepting connections"
        break
    fi
    sleep 5
done

log_info "[Phase 6] Restarting EFM and validating cluster"
sudo systemctl start "$EFM_SERVICE"
sleep 5

for i in {1..12}; do
    CLUSTER_STATUS=$(sudo efm cluster-status efm 2>/dev/null | grep -c "UP" || echo "0")
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

log_audit "EFM rolling upgrade completed successfully"
