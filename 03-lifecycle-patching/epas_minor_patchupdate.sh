#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/logger.sh"

trap 'log_warn "Operation interrupted."; exit 130' INT TERM HUP

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <target_version_number>"
    exit 1
fi
VERSION="$1"
SERVICE_NAME="edb-as-${VERSION}"

[[ "$VERSION" =~ ^[0-9]+$ ]] || { log_error "Version must be numeric"; exit 1; }

log_info "Beginning Patch Sequence for ${SERVICE_NAME}"
sudo systemctl stop "$SERVICE_NAME"

log_info "Executing system minor level DNF updates..."
dnf upgrade -y "edb-as${VERSION}-server*"

log_info "Restarting database instances..."
sudo systemctl start "$SERVICE_NAME"

if [ -x "/usr/edb/as${VERSION}/bin/edb_sqlpatch" ]; then
    log_info "Running engine local database catalog adjustments..."
    sudo -u enterprisedb "/usr/edb/as${VERSION}/bin/edb_sqlpatch" -af || { log_error "edb_sqlpatch failed"; exit 1; }
fi
log_audit "Engine update completed successfully for ${SERVICE_NAME}"
