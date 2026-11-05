#!/usr/bin/env bash
# =============================================================================
# epas-base-build.sh - compatibility wrapper (will be removed in a later release)
#
# The Day-1 build is now two scripts:
#   epas-base-build-root.sh   as root            packages, binaries, dirs, systemd, registry dir, /etc/edb/tde
#   epas-base-build-db.sh     as SYSTEM_USER     TDE passphrase file, initdb, conf.d, registry entry
#
# This wrapper runs both in order (the second one as SYSTEM_USER), for hosts where one
# person does the whole build. Use the two scripts directly when sysadmins run part A.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--tag DEV|SIT|PAT|PROD] [--yes]
Runs epas-base-build-root.sh (as root), then epas-base-build-db.sh as SYSTEM_USER.
\$TDE_PASSPHRASE, if exported, is passed on to part B. See --help of the two scripts.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
TAG_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --tag)     [[ -n "${2:-}" && "${2:-}" != --* ]] || die "--tag needs a value (DEV|SIT|PAT|PROD)"; TAG_ARGS=(--tag "$2"); shift 2 ;;
        --tag=*)   TAG_ARGS=(--tag "${1#--tag=}"); shift ;;
        *)         die "Unknown option: $1 (see --help)" ;;
    esac
done
require_root
load_env required

log_warn "epas-base-build.sh is now a wrapper: it runs epas-base-build-root.sh, then epas-base-build-db.sh as ${SYSTEM_USER}. Use those two directly; this name will be removed in a later release."

COMMON=()
[[ -n "${ENV_FILE:-}" ]] && COMMON+=(--env "$(readlink -f "$ENV_FILE")")
YES_ARGS=()
[[ "$ASSUME_YES" == "1" ]] && { COMMON+=(--yes); YES_ARGS=(--yes); }

bash "${SCRIPT_DIR}/epas-base-build-root.sh" "${COMMON[@]+"${COMMON[@]}"}"

# Part B runs as SYSTEM_USER (created by the packages in part A): it must be able to read the toolkit and the config.
ENV_ABS="$(readlink -f "$ENV_SOURCE")"
for f in "${SCRIPT_DIR}/epas-base-build-db.sh" "${TOOLKIT_ROOT}/lib/common.sh" "$ENV_ABS"; do
    sudo -u "$SYSTEM_USER" test -r "$f" \
        || die "${SYSTEM_USER} cannot read ${f}. Install the toolkit where ${SYSTEM_USER} can read it (sudo tools/install.sh -> /opt/edb_toolkit), then run part B:  sudo -iu ${SYSTEM_USER} ${SCRIPT_DIR}/epas-base-build-db.sh ${TAG_ARGS[*]-}"
done

cd /
sudo -H -u "$SYSTEM_USER" --preserve-env=TDE_PASSPHRASE \
    bash "${SCRIPT_DIR}/epas-base-build-db.sh" --env "$ENV_ABS" "${YES_ARGS[@]+"${YES_ARGS[@]}"}" "${TAG_ARGS[@]+"${TAG_ARGS[@]}"}"
