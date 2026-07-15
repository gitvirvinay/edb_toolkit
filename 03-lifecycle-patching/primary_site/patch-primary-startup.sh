#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../config/logger.sh"

if [ -f "../config.env" ]; then source "../config.env"; fi

EPAS_SERVICE="${EPAS_SERVICE:-edb-as-17}"
EFM_SERVICE="${EFM_SERVICE:-edb-efm-5.3}"

log_info "Reconnecting Primary Node Infrastructure"
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

log_info "Validating EFM clustering framework attachment..."
for i in {1..12}; do
    if sudo efm cluster-status efm &>/dev/null; then
        log_info "EFM cluster status: healthy"
        exit 0
    fi
    log_warn "Waiting for EFM to stabilize... ($i/12)"
    sleep 5
done
log_warn "EFM status check timed out. Verify manually with: sudo efm cluster-status efm"
