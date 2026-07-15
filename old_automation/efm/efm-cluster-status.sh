#!/bin/bash
# ==============================================================================
# Script Name: efm-cluster-status.sh
# Description: Lightweight wrapper to extract real-time EFM HA cluster health status.
# Usage:       sudo ./efm-cluster-status.sh <cluster_name> <efm_version>
# sudo ./efm-cluster-status.sh billing_cluster 5.3
# ==============================================================================

set -euo pipefail

CLUSTER_NAME="${1:-}"
EFM_VER="${2:-}"

if [[ -z "${CLUSTER_NAME}" || -z "${EFM_VER}" ]]; then
    echo "ERROR: Missing arguments." >&2
    echo "Usage: sudo $0 <cluster_name> <efm_version> (e.g., sudo $0 my_cluster 5.3)" >&2
    exit 1
fi

BINARY_PATH="/usr/edb/efm-${EFM_VER}/bin/efm"

if [[ ! -x "${BINARY_PATH}" ]]; then
    echo "ERROR: EFM binary not found or not executable at: ${BINARY_PATH}" >&2
    exit 1
fi

echo "Retrieving cluster status for '${CLUSTER_NAME}' (EFM ${EFM_VER})..."
echo "----------------------------------------------------------------------"
"${BINARY_PATH}" cluster-status "${CLUSTER_NAME}"