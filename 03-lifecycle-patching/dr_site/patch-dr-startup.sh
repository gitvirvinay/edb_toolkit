#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/logger.sh"

if [ -f "../config.env" ]; then source "../config.env"; fi

EPAS_SERVICE="${EPAS_SERVICE:-edb-as-17}"
EFM_SERVICE="${EFM_SERVICE:-edb-efm-5.3}"

log_info "Recovering Cascaded Standby Node"
sudo systemctl enable "$EPAS_SERVICE"
sudo systemctl start "$EPAS_SERVICE"

for i in {1..12}; do
    if sudo -u enterprisedb pg_isready -q; then
        log_info "EPAS is accepting connections."
        break
    fi
    log_warn "Waiting for EPAS to start... ($i/12)"
    sleep 5
done

sudo systemctl enable "$EFM_SERVICE"
sudo systemctl start "$EFM_SERVICE"
log_audit "DR standby node recovered and rejoined cluster"
