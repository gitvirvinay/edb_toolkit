#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/logger.sh"

if [ -f "../config.env" ]; then source "../config.env"; fi

EPAS_SERVICE="${EPAS_SERVICE:-edb-as-17}"
EFM_SERVICE="${EFM_SERVICE:-edb-efm-5.3}"

log_info "Isolating Primary Node Infrastructure"
sudo systemctl stop "$EFM_SERVICE" || true
sudo systemctl disable "$EFM_SERVICE"

log_info "Releasing Cluster VIP networks..."
ip addr show | grep -E "inet .* scope global" || true

sudo systemctl stop "$EPAS_SERVICE" || true
sudo systemctl disable "$EPAS_SERVICE"
log_audit "Primary node isolated cleanly for system level host maintenance"
