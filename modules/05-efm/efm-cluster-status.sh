#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env]
Shows EFM cluster status and checks that at least 2 nodes are UP (read-only).
Settings (config file or environment): EFM_CLUSTER_NAME (default: efm), EFM_VERSION.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env optional

CLUSTER_NAME="${CLUSTER_NAME:-${EFM_CLUSTER_NAME:-efm}}"
show_config EFM_SERVICE CLUSTER_NAME

log_info "Checking EFM Cluster Status"
sudo "$(efm_bin)" cluster-status "$CLUSTER_NAME" || {
    log_error "Failed to retrieve EFM cluster status"
    exit 1
}

log_info "Performing extended health validation"
NODE_COUNT=$(sudo "$(efm_bin)" cluster-status "$CLUSTER_NAME" 2>/dev/null | grep -c "Agent status" || echo "0")
UP_COUNT=$(sudo "$(efm_bin)" cluster-status "$CLUSTER_NAME" 2>/dev/null | grep -c "UP" || echo "0")

log_info "Cluster nodes: ${NODE_COUNT}, UP: ${UP_COUNT}"

if [ "$UP_COUNT" -lt 2 ]; then
    log_warn "Cluster quorum may be at risk. Only ${UP_COUNT} node(s) UP."
    exit 1
fi

log_info "EFM cluster health check passed"
