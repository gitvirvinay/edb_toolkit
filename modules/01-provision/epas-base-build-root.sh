#!/usr/bin/env bash
# =============================================================================
# epas-base-build-root.sh - Day-1 build, part A of 2 (ROOT)
#
# Everything on a new host that needs root, and nothing else:
#   1. EPAS packages (dnf)
#   2. binaries moved to BINARY_TOP, SRC_BINARY_DIR left as a compatibility symlink
#   3. DATA_TOP created; BINARY_TOP and DATA_TOP owned by SYSTEM_USER:SYSTEM_GROUP
#   4. systemd drop-in for SERVICE_NAME (User/Group/PGDATA/PIDFile)
#   5. cluster registry directory /etc/edb/toolkit   (tools/epastab.sh init)
#   6. TDE passphrase directory  /etc/edb/tde        (SYSTEM_USER, mode 0700)
#
# Part B, epas-base-build-db.sh, then runs as SYSTEM_USER (no root): initdb with
# TDE, conf.d templates, registry entry.
#
# Run it as root - by a sysadmin with sudo, or by automation (Ansible: become: true).
# It calls no sudo itself, so no sudoers whitelist is needed. Safe to re-run:
# every step checks what is already there.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--yes]
Day-1 build, part A (root): EPAS packages, binaries moved to BINARY_TOP with SRC_BINARY_DIR as a
compatibility symlink, DATA_TOP and ownership, systemd drop-in, registry directory (epastab.sh init),
TDE passphrase directory TDE_PASS_DIR (default /etc/edb/tde, owned by SYSTEM_USER, mode 0700).
Then, as SYSTEM_USER:  ${SCRIPT_DIR}/epas-base-build-db.sh --tag <DEV|SIT|PAT|PROD>
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
require_root
load_env required

TDE_PASS_DIR="${TDE_PASS_DIR:-/etc/edb/tde}"

# ==========================================
# SAFEGUARDS & VALIDATION
# ==========================================
[[ "$EPAS_VERSION" =~ ^[0-9]+$ ]] || die "EPAS_VERSION must be numeric"
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid SERVICE_NAME"
require_vars SYSTEM_USER SYSTEM_GROUP SRC_BINARY_DIR BINARY_TOP DATA_TOP
[[ "$SYSTEM_USER" != root ]] || die "SYSTEM_USER must be the database OS user, not root"
# Only a REAL directory SRC_BINARY_DIR can be lost: once the build has run, SRC_BINARY_DIR is the
# compatibility symlink to BINARY_TOP, which is the expected state on a re-run (the old script stopped here).
if [[ ! -L "$SRC_BINARY_DIR" && "$(readlink -m "$BINARY_TOP")" == "$(readlink -m "$SRC_BINARY_DIR")" ]]; then
    die "BINARY_TOP and SRC_BINARY_DIR are the same directory (${BINARY_TOP}); the binary move would remove the EDB install. Use a different BINARY_TOP."
fi
[[ "$TDE_PASS_DIR" == /* && "$TDE_PASS_DIR" =~ ^[A-Za-z0-9._/-]+$ && "$TDE_PASS_DIR" != *..* ]] \
    || die "Invalid TDE_PASS_DIR '${TDE_PASS_DIR}': absolute path, letters/digits and . _ - / only"

show_config EPAS_VERSION SERVICE_NAME SYSTEM_USER SYSTEM_GROUP SRC_BINARY_DIR BINARY_TOP DATA_TOP TDE_PASS_DIR
confirm_or_exit "prepare this host for EPAS ${EPAS_VERSION} as root: install packages, move binaries to ${BINARY_TOP} (symlink ${SRC_BINARY_DIR}), create ${DATA_TOP}, systemd drop-in for ${SERVICE_NAME}, registry and ${TDE_PASS_DIR} owned by ${SYSTEM_USER}"

log_info "START: EPAS ${EPAS_VERSION} build, part A (root)"
PACKAGE_NAME="edb-as${EPAS_VERSION}-server"

# ==========================================
# PACKAGE INSTALLATION (RESILIENT LOOP)
# ==========================================
# NOTE: pgaudit / pg_cron are referenced in conf.d/04-extensions.conf (part B).
#       Uncomment the matching lines below (or install separately) BEFORE the
#       first cluster start, or the server will fail to boot.
# ==========================================
PACKAGES=(
    "$PACKAGE_NAME"
    "${PACKAGE_NAME}-edb_wait_states"
    "edb-as${EPAS_VERSION}-query-advisor*"
    "edb-as${EPAS_VERSION}-stat_monitor*"
    #"edb-pg${EPAS_VERSION}-pgaudit*"
    #"edb-pg${EPAS_VERSION}-pg-cron*"
    #"pg_repack"
    "edb-lasso"
    "edb-pwr"
    "${PACKAGE_NAME}-contrib"
    "${PACKAGE_NAME}-pldebugger"
    "${PACKAGE_NAME}-plpython3"
    "${PACKAGE_NAME}-plperl"
    "${PACKAGE_NAME}-pltcl"
    "${PACKAGE_NAME}-sslutils"
    "${PACKAGE_NAME}-sqlprofiler"
    "${PACKAGE_NAME}-sqlprotect"
)

log_info "Evaluating and installing EPAS system packages..."
FAILED_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if ! dnf list installed "$pkg" &>/dev/null; then
        log_info "Installing package: $pkg"
        if ! dnf install -y "$pkg"; then
            log_warn "Could not install $pkg. Skipping..."
            FAILED_PACKAGES+=("$pkg")
        fi
    fi
done
if [ ${#FAILED_PACKAGES[@]} -ne 0 ]; then
    log_warn "Warning: The following packages could not be installed: ${FAILED_PACKAGES[*]}"
fi

# The EDB server package creates the OS account; check it only now.
id "$SYSTEM_USER" >/dev/null 2>&1 || die "OS user '${SYSTEM_USER}' does not exist (normally created by ${PACKAGE_NAME})"
getent group "$SYSTEM_GROUP" >/dev/null 2>&1 || die "OS group '${SYSTEM_GROUP}' does not exist"

# ==========================================
# BINARY ROTATION, INSTALL & COMPATIBILITY SYMLINK
# ==========================================
log_info "Configuring EPAS binary location: ${BINARY_TOP}"
log_info "Compatibility path: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"

mkdir -p "$DATA_TOP"

if [[ -L "$SRC_BINARY_DIR" ]]; then
    CURRENT_TARGET="$(readlink -f "$SRC_BINARY_DIR" 2>/dev/null || true)"
    EXPECTED_TARGET="$(readlink -f "$BINARY_TOP" 2>/dev/null || true)"
    if [[ "$CURRENT_TARGET" == "$EXPECTED_TARGET" && -d "$BINARY_TOP/bin" ]]; then
        log_info "${SRC_BINARY_DIR} already points to ${BINARY_TOP}; no binary copy required."
    else
        log_warn "${SRC_BINARY_DIR} is a symlink but does not point to ${BINARY_TOP}. Replacing."
        rm -f "$SRC_BINARY_DIR"
    fi
fi

if [[ -d "$SRC_BINARY_DIR" && ! -L "$SRC_BINARY_DIR" ]]; then
    mkdir -p "$BINARY_TOP"
    if [[ -d "$BINARY_TOP/bin" ]]; then
        BACKUP_BIN="${BINARY_TOP}_bak_$(date +%F_%H%M%S)"
        log_warn "Existing binaries found in ${BINARY_TOP}. Rotating to ${BACKUP_BIN}"
        mv "$BINARY_TOP" "$BACKUP_BIN"
        mkdir -p "$BINARY_TOP"
    fi
    log_info "Migrating EPAS binaries from ${SRC_BINARY_DIR} to ${BINARY_TOP}"
    cp -a "${SRC_BINARY_DIR}/." "$BINARY_TOP/"
    log_info "Removing duplicate physical EPAS directory: ${SRC_BINARY_DIR}"
    rm -rf "$SRC_BINARY_DIR"
fi

[[ -d "$BINARY_TOP/bin" ]] || die "EPAS binaries were not found in ${BINARY_TOP}/bin"

if [[ ! -e "$SRC_BINARY_DIR" && ! -L "$SRC_BINARY_DIR" ]]; then
    log_info "Creating compatibility symlink: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"
    ln -s "$BINARY_TOP" "$SRC_BINARY_DIR"
elif [[ -L "$SRC_BINARY_DIR" ]]; then
    log_info "Compatibility symlink already configured: ${SRC_BINARY_DIR} -> $(readlink "$SRC_BINARY_DIR")"
else
    die "${SRC_BINARY_DIR} still exists as a physical directory; refusing to overwrite it."
fi

# ==========================================
# PERMISSIONS & OWNERSHIP (BEFORE INITDB)
# ==========================================
log_info "Configuring directory ownership to ${SYSTEM_USER}:${SYSTEM_GROUP}"
chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$BINARY_TOP" "$DATA_TOP"
log_info "EPAS binaries: ${BINARY_TOP} (single physical copy)"
log_info "EDB compatibility path: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"

# ==========================================
# SYSTEMD SERVICE CONFIGURATION (DROP-IN)
# ==========================================
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
if [ -f "/usr/lib/systemd/system/${SERVICE_NAME}.service" ]; then
    log_info "Creating Systemd Unit Overrides in ${SYSTEMD_OVERRIDE_DIR}/override.conf"
    mkdir -p "$SYSTEMD_OVERRIDE_DIR"
    cat > "${SYSTEMD_OVERRIDE_DIR}/override.conf" <<SYS_EOF
[Service]
User=${SYSTEM_USER}
Group=${SYSTEM_GROUP}
Environment=PGDATA=${DATA_TOP}
PIDFile=${DATA_TOP}/postmaster.pid
SYS_EOF
    systemctl daemon-reload
else
    log_warn "Unit /usr/lib/systemd/system/${SERVICE_NAME}.service not found - no systemd drop-in written (cluster will be pg_ctl-managed)"
fi

# ==========================================
# CLUSTER REGISTRY DIRECTORY (/etc/edb/toolkit)
# ==========================================
# Run it in a child shell with its own options: epastab reads the owner from --owner, not from site.env.
log_info "Preparing the cluster registry directory (epastab.sh init)"
"${TOOLKIT_ROOT}/tools/epastab.sh" init --owner "${SYSTEM_USER}:${SYSTEM_GROUP}" --yes

# ==========================================
# TDE PASSPHRASE DIRECTORY (/etc/edb/tde)
# ==========================================
# /etc/edb stays root's (EDB packages keep files there); only this subdirectory is
# delegated, so part B can write /etc/edb/tde/<cluster>.pass without root.
# Mode 0700: nobody but SYSTEM_USER (and root) can even list the file names.
mkdir -p "$(dirname "$TDE_PASS_DIR")"
if [[ -d "$TDE_PASS_DIR" ]]; then
    CUR_TDE="$(stat -c '%U:%G %a' "$TDE_PASS_DIR")"
    if [[ "$CUR_TDE" == "${SYSTEM_USER}:${SYSTEM_GROUP} 700" ]]; then
        log_info "${TDE_PASS_DIR} already set up (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 700)"
    else
        log_warn "${TDE_PASS_DIR} was ${CUR_TDE}; setting ${SYSTEM_USER}:${SYSTEM_GROUP} 700"
        chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$TDE_PASS_DIR"
        chmod 0700 "$TDE_PASS_DIR"
    fi
else
    install -d -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" -m 0700 "$TDE_PASS_DIR"
    log_info "Created ${TDE_PASS_DIR} (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 700)"
fi

log_audit "Day 1 part A (root) done: EPAS ${EPAS_VERSION}, binaries ${BINARY_TOP}, data dir ${DATA_TOP}, service ${SERVICE_NAME}, TDE dir ${TDE_PASS_DIR}"

ENV_HINT=""
[[ -n "${ENV_FILE:-}" ]] && ENV_HINT=" --env $(readlink -f "$ENV_FILE")"
log_info "Next, as ${SYSTEM_USER} (no root needed):"
log_info "  sudo -iu ${SYSTEM_USER} ${SCRIPT_DIR}/epas-base-build-db.sh${ENV_HINT} --tag <DEV|SIT|PAT|PROD>"
