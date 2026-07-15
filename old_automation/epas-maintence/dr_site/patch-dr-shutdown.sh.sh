#!/usr/bin/env bash
# dr_shutdown.sh
#Run this on all DR Site nodes before the DR Site patching window.
# Script to safely isolate, stop, and disable DR Cascaded Standbys
set -euo pipefail

EFM_SERVICE="edb-efm-5.3"
EPAS_SERVICE="edb-as-15"

echo "=== Starting DR Node Isolate & Shutdown Sequence ==="

# 1. Kill EFM Cluster tracking first
if systemctl is-active --quiet $EFM_SERVICE; then
    echo "Stopping DR EFM Agent..."
    sudo systemctl stop $EFM_SERVICE
fi
sudo systemctl disable $EFM_SERVICE

# 2. Stop DR Cascaded Database Instance
if systemctl is-active --quiet $EPAS_SERVICE; then
    echo "Stopping DR EPAS 15 Engine..."
    sudo systemctl stop $EPAS_SERVICE
fi
sudo systemctl disable $EPAS_SERVICE

echo "=== DR Node safely isolated and disabled ==="