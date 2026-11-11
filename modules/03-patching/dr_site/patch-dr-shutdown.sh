#!/usr/bin/env bash
# patch-dr-shutdown.sh — secure a DR (cascaded standby) node before patching:
# stop & disable EFM, then stop EPAS (it stays enabled).
# EPAS stays ENABLED: it starts by itself after the reboot (it is not the HA brain). EFM is disabled, so after a
# reboot no agent joins the cluster before the node has been checked - patch-*-startup.sh enables it again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [--yes]
Stops and disables EFM, then stops EPAS (left enabled), on this DR-site node (run before patching).
Settings: EPAS_VERSION/SERVICE_NAME, EFM_VERSION — from conf/site.env (required).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
load_env required
show_config EPAS_VERSION EPAS_SERVICE EFM_SERVICE
confirm_or_exit "stop and disable ${EFM_SERVICE}, then stop ${EPAS_SERVICE} on DR node $(hostname -s)"

log_info "Securing Cascaded Standby Node"
sudo systemctl stop "$EFM_SERVICE" || true
sudo systemctl disable "$EFM_SERVICE"

sudo systemctl stop "$EPAS_SERVICE" || true
log_audit "DR standby node secured for maintenance (${EPAS_SERVICE}, ${EFM_SERVICE})"
