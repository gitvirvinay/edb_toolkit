#!/usr/bin/env bash
# patch-dr-startup.sh — bring a DR (cascaded standby) node back after patching:
# enable & start EPAS, wait until it accepts connections, then enable & start EFM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes]
Enables and starts EPAS, waits for it on PRIMARY_PORT, then enables and starts EFM.
EFM is NOT started if EPAS does not come up within 60 s.
Settings: EPAS_VERSION, EFM_VERSION, SYSTEM_USER, PRIMARY_PORT — from conf/site.env (required).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required
show_config EPAS_SERVICE EFM_SERVICE SYSTEM_USER PRIMARY_PORT
confirm_or_exit "enable and start ${EPAS_SERVICE}, then ${EFM_SERVICE} on DR node $(hostname -s)"

log_info "Recovering Cascaded Standby Node"
sudo systemctl enable "$EPAS_SERVICE"
sudo systemctl start "$EPAS_SERVICE"

wait_for_epas 12 5 || die "EPAS did not accept connections on port ${PRIMARY_PORT} within 60s — EFM NOT started. Check: sudo systemctl status ${EPAS_SERVICE}"

sudo systemctl enable "$EFM_SERVICE"
sudo systemctl start "$EFM_SERVICE"
log_audit "DR standby node recovered and rejoined cluster (${EPAS_SERVICE}, ${EFM_SERVICE})"
