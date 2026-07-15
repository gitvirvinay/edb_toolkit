#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/logger.sh"

if [ -f "../config.env" ]; then source "../config.env"; fi

EPAS_SERVICE="${EPAS_SERVICE:-edb-as-17}"
EFM_SERVICE="${EFM_SERVICE:-edb-efm-5.3}"

log_info "Securing Cascaded Standby Node"
sudo systemctl stop "$EFM_SERVICE" || true
sudo systemctl disable "$EFM_SERVICE"

sudo systemctl stop "$EPAS_SERVICE" || true
sudo systemctl disable "$EPAS_SERVICE"
log_audit "DR standby node secured for maintenance"
