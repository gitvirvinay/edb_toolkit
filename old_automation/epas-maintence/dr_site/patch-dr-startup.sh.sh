#!/usr/bin/env bash
# dr_startup.sh
#Run this sequentially across the DR nodes  post-patching.
# Script to safely rejoin DR Cascaded Standbys to their independent cluster
set -euo pipefail

EFM_SERVICE="edb-efm-5.3"
EPAS_SERVICE="edb-as-15"

echo "=== Starting DR Node Rejoin Sequence ==="

# 1. Bring up database to catch up on WAL
echo "Enabling and Starting DR EPAS 15..."
sudo systemctl enable $EPAS_SERVICE
sudo systemctl start $EPAS_SERVICE

echo "Waiting 10 seconds for replication catch-up initiation..."
sleep 10

# 2. Resume separate DR EFM clustering
echo "Enabling and Starting DR EFM Agent..."
sudo systemctl enable $EFM_SERVICE
sudo systemctl start $EFM_SERVICE

echo "=== DR Node configuration complete ==="