#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

EFM_SERVICE="${EFM_SERVICE:-edb-efm-5.3}"
CLUSTER_NAME="${CLUSTER_NAME:-efm}"

log_info "Checking EFM Cluster Status"
sudo efm cluster-status "$CLUSTER_NAME" || {
    log_error "Failed to retrieve EFM cluster status"
    exit 1
}

log_info "Performing extended health validation"
NODE_COUNT=$(sudo efm cluster-status "$CLUSTER_NAME" 2>/dev/null | grep -c "Agent status" || echo "0")
UP_COUNT=$(sudo efm cluster-status "$CLUSTER_NAME" 2>/dev/null | grep -c "UP" || echo "0")

log_info "Cluster nodes: ${NODE_COUNT}, UP: ${UP_COUNT}"

if [ "$UP_COUNT" -lt 2 ]; then
    log_warn "Cluster quorum may be at risk. Only ${UP_COUNT} node(s) UP."
    exit 1
fi

log_info "EFM cluster health check passed"
