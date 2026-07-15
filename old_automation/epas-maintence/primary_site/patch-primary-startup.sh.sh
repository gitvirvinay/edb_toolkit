#!/usr/bin/env bash
# Script to safely enable and start EPAS 15 and EFM 5.3 on Primary Cluster Nodes
# primary_startup.sh
# Run this on the Primary Node first, then on the two Primary Standbys after OS patching
set -euo pipefail

EFM_SERVICE="edb-efm-5.3"
EPAS_SERVICE="edb-as-15"

echo "=== Starting Primary Node Bring-Up Sequence ==="

# 1. Enable and Start Database Engine
echo "Enabling EPAS 15..."
sudo systemctl enable $EPAS_SERVICE

echo "Starting EPAS 15..."
sudo systemctl start $EPAS_SERVICE

# 2. Enable and Start EFM Cluster Management
echo "Enabling EFM 5.3..."
sudo systemctl enable $EFM_SERVICE

echo "Starting EFM 5.3..."
sudo systemctl start $EFM_SERVICE

# 3. Health Check
echo "Checking local service status..."
sudo systemctl status $EPAS_SERVICE --no-pager
sudo systemctl status $EFM_SERVICE --no-pager

echo "=== Priming Check: Verify cluster state manually using 'efm cluster-status efm' ==="