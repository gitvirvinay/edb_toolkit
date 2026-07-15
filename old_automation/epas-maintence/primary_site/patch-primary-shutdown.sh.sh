#!/usr/bin/env bash
# primary_shutdown.sh
# Script to safely stop and disable EPAS 15 and EFM 5.3 on Primary Cluster Nodes
#Run this on all Primary Site nodes before the Primary Site patching window.
set -euo pipefail

CLUSTER_NAME="efm"
EFM_SERVICE="edb-efm-5.3"
EPAS_SERVICE="edb-as-15"

echo "=== Starting Primary Node Shutdown Sequence ==="

# 1. Stop and Disable EFM to prevent false failover / isolate VIP
if systemctl is-active --quiet $EFM_SERVICE; then
    echo "Stopping EFM Service ($EFM_SERVICE)..."
    sudo systemctl stop $EFM_SERVICE
fi

echo "Disabling EFM Service..."
sudo systemctl disable $EFM_SERVICE

# 2. Verify VIP is released (Targeted caution for Master node)
echo "Verifying network interface state..."
ip addr show

# 3. Stop and Disable EPAS Database Engine
if systemctl is-active --quiet $EPAS_SERVICE; then
    echo "Stopping EPAS 15 Database ($EPAS_SERVICE)..."
    sudo systemctl stop $EPAS_SERVICE
fi

echo "Disabling EPAS 15 Database..."
sudo systemctl disable $EPAS_SERVICE

echo "=== Node is safe for automated OS patching and reboots ==="