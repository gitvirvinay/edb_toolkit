#!/usr/bin/env bash
# =============================================================================
# epas-base-build-root.sh - Day-1 build, part A of 2 (ROOT)
#
# Everything on a new host that needs root, and nothing else:
#   1. EPAS packages (dnf)
#   2. binaries moved to BINARY_TOP, SRC_BINARY_DIR left as a compatibility symlink
#   3. storage folders created and owned by SYSTEM_USER:SYSTEM_GROUP (mode 0700): DATA_TOP and,
#      when set, WAL_TOP, ARCHIVE_TOP, BACKUP_TOP, LOG_TOP; their parent (the mount, e.g. /pgdata)
#      is handed to SYSTEM_USER too (mode 0750), so a standby rebuild can move DATA_TOP aside.
#      Then a mount check: warns when a folder is on / or shares a filesystem with DATA_TOP.
#   4. systemd drop-in for SERVICE_NAME (User/Group/PGDATA/PIDFile, RequiresMountsFor= the
#      data, WAL and log folders, so the service never starts before those mounts are there)
#   5. cluster registry directory /etc/edb/toolkit   (tools/epastab.sh init)
#   6. TDE passphrase directory  /etc/edb/tde        (SYSTEM_USER, mode 0700)
#   7. SSL directory SECURITY_TOP /etc/edb/ssl        (SYSTEM_USER, mode 0700; used by 02-ssl)
#   8. toolkit log directory TOOLKIT_LOG_DIR, default <LOG_MOUNT>/toolkit (SYSTEM_USER, mode 2750),
#      so no toolkit script ever needs sudo to write its log (lib/logger.sh)
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
# shellcheck source=../../lib/epas-layout.sh
source "${SCRIPT_DIR}/../../lib/epas-layout.sh"

usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [--yes]
Day-1 build, part A (root): EPAS packages, binaries moved to BINARY_TOP with SRC_BINARY_DIR as a
compatibility symlink, storage folders (DATA_TOP, WAL_TOP, ARCHIVE_TOP, BACKUP_TOP, LOG_TOP) and
ownership, mount check, systemd drop-in, registry directory (epastab.sh init),
TDE passphrase directory TDE_PASS_DIR (default /etc/edb/tde, owned by SYSTEM_USER, mode 0700),
SSL directory SECURITY_TOP (default /etc/edb/ssl, owned by SYSTEM_USER, mode 0700; skipped if it is inside DATA_TOP),
toolkit log directory TOOLKIT_LOG_DIR (default <LOG_MOUNT>/toolkit, owned by SYSTEM_USER, mode 2750).
Then, as SYSTEM_USER:  ${SCRIPT_DIR}/epas-base-build-db.sh --tag <DEV|SIT|PAT|PROD>
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
require_root
load_env required

TDE_PASS_DIR="${TDE_PASS_DIR:-/etc/edb/tde}"
SECURITY_TOP="${SECURITY_TOP:-/etc/edb/ssl}"
TOOLKIT_LOG_DIR="$(log_dir)"                 # same rule as lib/logger.sh: TOOLKIT_LOG_DIR, else <LOG_MOUNT>/toolkit
TOOLKIT_LOG_DIR="${TOOLKIT_LOG_DIR%/}"

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
[[ "$SECURITY_TOP" == /* && "$SECURITY_TOP" =~ ^[A-Za-z0-9._/-]+$ && "$SECURITY_TOP" != *..* ]] \
    || die "Invalid SECURITY_TOP '${SECURITY_TOP}': absolute path, letters/digits and . _ - / only"
# Storage layout: every folder that is set must be a safe absolute path, and none may sit inside another
# (initdb needs an empty DATA_TOP; a WAL or log folder inside PGDATA would be copied by pg_basebackup).
LAYOUT_SET=()
for v in $(epas_layout_vars); do
    [[ -n "${!v:-}" ]] || continue
    epas_layout_valid_path "${!v}" || die "Invalid ${v} '${!v}': absolute path, letters/digits and . _ - + / only"
    printf -v "$v" '%s' "${!v%/}"
    LAYOUT_SET+=("$v")
done
for a in "${LAYOUT_SET[@]}"; do
    for b in "${LAYOUT_SET[@]}"; do
        [[ "$a" != "$b" ]] || continue
        ra="$(readlink -m "${!a}")"; rb="$(readlink -m "${!b}")"
        [[ "$ra" != "$rb" ]] || die "${a} and ${b} are the same directory (${ra}) - each needs its own folder"
        case "$ra/" in "$rb"/*) die "${a} (${ra}) is inside ${b} (${rb}) - use separate folders, ideally separate mounts" ;; esac
    done
done
for v in "${LAYOUT_SET[@]}"; do
    epas_layout_parent_ok "${!v}" || die "${v}=${!v}: its parent $(dirname "${!v}") is a system directory. Use a folder under a dedicated mount, e.g. /pgwal/${CLUSTER_NAME:-as${EPAS_VERSION}}"
done
# Toolkit log directory: same rules as the storage folders - a safe path, never inside a system directory.
if [[ -n "$TOOLKIT_LOG_DIR" ]]; then
    epas_layout_valid_path "$TOOLKIT_LOG_DIR" || die "Invalid TOOLKIT_LOG_DIR '${TOOLKIT_LOG_DIR}': absolute path, letters/digits and . _ - + / only"
    epas_layout_parent_ok "$TOOLKIT_LOG_DIR" || die "TOOLKIT_LOG_DIR=${TOOLKIT_LOG_DIR}: its parent $(dirname "$TOOLKIT_LOG_DIR") is a system directory. Use a folder on the log mount, e.g. /pglog/toolkit"
fi

# Old layout (SSL files inside PGDATA): never create it here - initdb (part B) needs an empty DATA_TOP.
SSL_IN_PGDATA=0
case "$(readlink -m "$SECURITY_TOP")/" in "$(readlink -m "$DATA_TOP")"/*) SSL_IN_PGDATA=1 ;; esac

show_config EPAS_VERSION SERVICE_NAME SYSTEM_USER SYSTEM_GROUP SRC_BINARY_DIR BINARY_TOP DATA_TOP WAL_TOP ARCHIVE_TOP BACKUP_TOP LOG_TOP TDE_PASS_DIR SECURITY_TOP TOOLKIT_LOG_DIR
LAYOUT_LIST=""
for v in "${LAYOUT_SET[@]}"; do LAYOUT_LIST+="${LAYOUT_LIST:+, }${!v}"; done
confirm_or_exit "prepare this host for EPAS ${EPAS_VERSION} as root: install packages, move binaries to ${BINARY_TOP} (symlink ${SRC_BINARY_DIR}), create ${LAYOUT_LIST}, systemd drop-in for ${SERVICE_NAME}, registry, ${TDE_PASS_DIR}, ${SECURITY_TOP} and the toolkit log directory ${TOOLKIT_LOG_DIR:-<none>} owned by ${SYSTEM_USER}"

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
chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$BINARY_TOP"

# ==========================================
# STORAGE FOLDERS (DATA_TOP, WAL_TOP, ARCHIVE_TOP, BACKUP_TOP, LOG_TOP)
# ==========================================
# <mount>/<cluster>, mode 0700. The parent (normally the mount itself, e.g. /pgwal) goes to SYSTEM_USER
# with mode 0750: epas-rebuild-standby.sh moves DATA_TOP/WAL_TOP aside to <TOP>_bak_<timestamp> next to
# them, and 04-upgrade puts its dump folder there - both as SYSTEM_USER, without root.
for v in "${LAYOUT_SET[@]}"; do
    top="${!v}"
    parent="$(dirname "$top")"
    if [[ ! -d "$parent" ]]; then
        install -d -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" -m 0750 "$parent"
        log_info "Created ${parent} (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 750)"
    elif [[ "$(stat -c '%U:%G' "$parent")" != "${SYSTEM_USER}:${SYSTEM_GROUP}" ]]; then
        log_warn "${parent} was $(stat -c '%U:%G %a' "$parent"); setting ${SYSTEM_USER}:${SYSTEM_GROUP} 750 (the cluster folders below it are moved and recreated by ${SYSTEM_USER})"
        chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$parent"
        chmod 0750 "$parent"
    fi
    if [[ -d "$top" ]]; then
        chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$top"
        chmod 0700 "$top"
        log_info "${v} ${top} exists (owner set to ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 700)"
    else
        install -d -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" -m 0700 "$top"
        log_info "Created ${v} ${top} (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 700)"
    fi
done

# Mount check: a folder on / or on the same filesystem as DATA_TOP is not protected (warning only).
LAYOUT_RC=0
LAYOUT_REPORT="$(epas_layout_check)" || LAYOUT_RC=$?
while IFS= read -r line; do
    case "$line" in
        WARN*) log_warn "Storage: ${line#WARN  }" ;;
        ?*)    log_info "Storage: ${line#OK    }" ;;
    esac
done <<< "$LAYOUT_REPORT"
(( LAYOUT_RC == 0 )) || log_warn "Storage layout is not fully separated (see above). Fine for a lab; for PAT/PROD ask for separate mounts before go-live."
log_info "EPAS binaries: ${BINARY_TOP} (single physical copy)"
log_info "EDB compatibility path: ${SRC_BINARY_DIR} -> ${BINARY_TOP}"

# ==========================================
# SYSTEMD SERVICE CONFIGURATION (DROP-IN)
# ==========================================
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
if [ -f "/usr/lib/systemd/system/${SERVICE_NAME}.service" ]; then
    log_info "Creating Systemd Unit Overrides in ${SYSTEMD_OVERRIDE_DIR}/override.conf"
    mkdir -p "$SYSTEMD_OVERRIDE_DIR"
    # RequiresMountsFor: systemd waits for (and requires) the mounts holding these folders, so the
    # service never starts on an empty mount point or writes WAL/logs onto the root filesystem.
    MOUNTS_FOR="$DATA_TOP"
    [[ -n "${WAL_TOP:-}" ]] && MOUNTS_FOR+=" ${WAL_TOP}"
    [[ -n "${LOG_TOP:-}" ]] && MOUNTS_FOR+=" ${LOG_TOP}"
    cat > "${SYSTEMD_OVERRIDE_DIR}/override.conf" <<SYS_EOF
[Unit]
RequiresMountsFor=${MOUNTS_FOR}

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

# ==========================================
# SSL DIRECTORY (SECURITY_TOP, default /etc/edb/ssl) - for module 02-ssl
# ==========================================
# One directory per HOST, outside PGDATA: pg_basebackup, standby rebuilds and backups never copy
# this host's key and passphrase to another host, and a major upgrade (new PGDATA) keeps using it.
# Owned by SYSTEM_USER, mode 0700, so epas-ssl-setup.sh runs as SYSTEM_USER without root.
if (( SSL_IN_PGDATA )); then
    log_warn "SECURITY_TOP ${SECURITY_TOP} is inside DATA_TOP (old layout) - not created here (initdb needs an empty data directory). Recommended: SECURITY_TOP=/etc/edb/ssl in ${ENV_SOURCE}"
elif [[ -d "$SECURITY_TOP" ]]; then
    CUR_SSL="$(stat -c '%U:%G %a' "$SECURITY_TOP")"
    if [[ "$CUR_SSL" == "${SYSTEM_USER}:${SYSTEM_GROUP} 700" ]]; then
        log_info "${SECURITY_TOP} already set up (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 700)"
    else
        log_warn "${SECURITY_TOP} was ${CUR_SSL}; setting ${SYSTEM_USER}:${SYSTEM_GROUP} 700"
        chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$SECURITY_TOP"
        chmod 0700 "$SECURITY_TOP"
    fi
else
    mkdir -p "$(dirname "$SECURITY_TOP")"
    install -d -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" -m 0700 "$SECURITY_TOP"
    log_info "Created ${SECURITY_TOP} (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 700)"
fi

# ==========================================
# TOOLKIT LOG DIRECTORY (TOOLKIT_LOG_DIR, default <LOG_MOUNT>/toolkit)
# ==========================================
# Where every toolkit script writes its run log (lib/logger.sh). Created here once, so the scripts
# never need sudo for logging. Owner SYSTEM_USER, mode 2750:
#   2   = setgid: a file created here gets this directory's group, also when root creates it,
#         so SYSTEM_USER can read the log of a root run (files are mode 640) but not change it
#   750 = owner writes, group reads, everyone else has no access
# Its parent must already exist (normally the log mount, handed to SYSTEM_USER above): creating
# /pglog here on a host without that mount would put the logs on the root filesystem.
if [[ -z "$TOOLKIT_LOG_DIR" ]]; then
    log_warn "No toolkit log directory: LOG_MOUNT is empty and TOOLKIT_LOG_DIR is not set, so toolkit scripts print on the screen only. Set TOOLKIT_LOG_DIR in ${ENV_SOURCE} and re-run."
elif [[ ! -d "$(dirname "$TOOLKIT_LOG_DIR")" ]]; then
    log_warn "Toolkit log directory ${TOOLKIT_LOG_DIR} not created: its parent $(dirname "$TOOLKIT_LOG_DIR") does not exist (is the log mount there?). Toolkit scripts print on the screen only until it exists; re-run this script afterwards."
elif [[ -d "$TOOLKIT_LOG_DIR" ]]; then
    CUR_TLOG="$(stat -c '%U:%G %a' "$TOOLKIT_LOG_DIR")"
    if [[ "$CUR_TLOG" == "${SYSTEM_USER}:${SYSTEM_GROUP} 2750" ]]; then
        log_info "${TOOLKIT_LOG_DIR} already set up (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 2750)"
    else
        log_warn "${TOOLKIT_LOG_DIR} was ${CUR_TLOG}; setting ${SYSTEM_USER}:${SYSTEM_GROUP} 2750"
        chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$TOOLKIT_LOG_DIR"
        chmod 2750 "$TOOLKIT_LOG_DIR"
    fi
else
    install -d -o "$SYSTEM_USER" -g "$SYSTEM_GROUP" -m 2750 "$TOOLKIT_LOG_DIR"
    log_info "Created ${TOOLKIT_LOG_DIR} (owner ${SYSTEM_USER}:${SYSTEM_GROUP}, mode 2750)"
fi
log_init                                     # the directory may be new: open this run's log file now
[[ -z "$(log_file)" ]] || log_info "Log of this run: $(log_file)"

log_audit "Day 1 part A (root) done: EPAS ${EPAS_VERSION}, binaries ${BINARY_TOP}, storage ${LAYOUT_LIST}, service ${SERVICE_NAME}, TDE dir ${TDE_PASS_DIR}, SSL dir ${SECURITY_TOP}, toolkit logs ${TOOLKIT_LOG_DIR:-<none>}"

ENV_HINT=""
[[ -n "${ENV_FILE:-}" ]] && ENV_HINT=" --env $(readlink -f "$ENV_FILE")"
log_info "Next, as ${SYSTEM_USER} (no root needed):"
log_info "  sudo -iu ${SYSTEM_USER} ${SCRIPT_DIR}/epas-base-build-db.sh${ENV_HINT} --tag <DEV|SIT|PAT|PROD>"
