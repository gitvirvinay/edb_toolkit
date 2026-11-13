#!/usr/bin/env bash
# epas-minor-update.sh — update the EPAS packages on a node without EFM:
# stop EPAS, dnf upgrade edb-as<ver>-server*, start EPAS, run edb_sqlpatch.
# For a node without EFM: refuses to run while an EFM agent is active on the host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

trap 'log_warn "Operation interrupted."; exit 130' INT TERM HUP

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--yes] [<version>]
Stops EPAS, applies minor updates with dnf, restarts EPAS and runs edb_sqlpatch.
<version> defaults to EPAS_VERSION from conf/site.env. Must run as root.
For a node WITHOUT EFM: it stops if an EFM agent is running here (use epas-minor-update-efm.sh there).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; esac
[ "$#" -le 1 ] || die "Too many arguments (see --help)"
VERSION_ARG="${1:-}"
load_env required
# This script stops EPAS without telling EFM. Under a running EFM agent that looks like a database
# failure and can cause a failover, so an EFM node is refused here, whatever HA_TOOL says.
EFM_AGENTS="$(efm_agents_running)"
[ -z "$EFM_AGENTS" ] || die "An EFM agent is running on this host (${EFM_AGENTS}). On a node of an EFM cluster use ${SCRIPT_DIR}/epas-minor-update-efm.sh, which stops the agent first. Nothing was changed."
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
