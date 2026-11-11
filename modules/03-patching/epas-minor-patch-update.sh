#!/usr/bin/env bash
# epas-minor-patch-update.sh — single-node minor patch:
# stop EPAS, dnf upgrade edb-as<ver>-server*, start EPAS, run edb_sqlpatch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

trap 'log_warn "Operation interrupted."; exit 130' INT TERM HUP

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--yes] [<version>]
Stops EPAS, applies minor updates with dnf, restarts EPAS and runs edb_sqlpatch.
<version> defaults to EPAS_VERSION from conf/site.env. Must run as root.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; esac
[ "$#" -le 1 ] || die "Too many arguments (see --help)"
VERSION_ARG="${1:-}"
load_env required
require_root

VERSION="${VERSION_ARG:-$EPAS_VERSION}"
[[ "$VERSION" =~ ^[0-9]+$ ]] || die "Version must be numeric: ${VERSION}"
SERVICE_NAME="edb-as-${VERSION}"
show_config VERSION SERVICE_NAME SYSTEM_USER
confirm_or_exit "stop ${SERVICE_NAME}, run 'dnf upgrade edb-as${VERSION}-server*', restart it and run edb_sqlpatch"

log_info "Beginning Patch Sequence for ${SERVICE_NAME}"
sudo systemctl stop "$SERVICE_NAME"

log_info "Executing system minor level DNF updates..."
dnf upgrade -y "edb-as${VERSION}-server*"

log_info "Restarting database instances..."
sudo systemctl start "$SERVICE_NAME"

if [ -x "/usr/edb/as${VERSION}/bin/edb_sqlpatch" ]; then
    log_info "Running engine local database catalog adjustments..."
    sudo -u "$SYSTEM_USER" "/usr/edb/as${VERSION}/bin/edb_sqlpatch" -af || die "edb_sqlpatch failed"
fi
log_audit "Engine update completed successfully for ${SERVICE_NAME}"
