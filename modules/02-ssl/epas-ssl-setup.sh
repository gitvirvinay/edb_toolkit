#!/usr/bin/env bash
set -euo pipefail
umask 077

# -----------------------------------------------------------------------------
# epas-ssl-setup.sh  -  Encrypted-key, file-based passphrase (Arch 2A)
#
# Runs as the DATABASE OS USER (SYSTEM_USER, e.g. enterprisedb) - never as root:
#   sudo -iu enterprisedb /opt/dba/edb_toolkit/modules/02-ssl/epas-ssl-setup.sh [--env conf/site.env] -b bundle.pem
# Every file it writes belongs to SYSTEM_USER. Root writing into SYSTEM_USER's directories would let
# that account redirect root's writes with symbolic links.
# Applying the change: a RUNNING cluster is RELOADED (pg_ctl reload - no downtime, no sudo; the new
# ssl.conf sets ssl_passphrase_command_supports_reload = on), then checked: no config errors, and the
# server presents the NEW certificate (openssl s_client -starttls postgres on 127.0.0.1). A stopped
# cluster, or --restart, is (re)started: systemd via conf/sudoers.d/epas-automation
# (sudo systemctl restart edb-as-NN), otherwise pg_ctl.
# Renewing a certificate = running this again with the new bundle.
#
# One-time root prerequisites:
#   - SECURITY_TOP (default /etc/edb/ssl), owned by SYSTEM_USER, mode 0700 - epas-base-build-root.sh
#     creates it, or: sudo install -d -o enterprisedb -g enterprisedb -m 0700 /etc/edb/ssl
#   - systemd-managed cluster: the sudoers file conf/sudoers.d/epas-automation
#
# PEM bundle order is ENFORCED. The certificates must be leaf first, root last (the TLS chain order);
# the private key goes at one end - after the root (recommended) or before the leaf (older bundles, still accepted):
#         -----BEGIN CERTIFICATE-----               (1) server/leaf  certificate
#         -----BEGIN CERTIFICATE-----               (2..n-1) intermediate(s), optional
#         -----BEGIN CERTIFICATE-----               (n) root CA      LAST certificate
#         -----BEGIN ENCRYPTED PRIVATE KEY-----     private key, after the root (or, older layout, before the leaf)
#   Results:
#       server_chained.crt = leaf + intermediate(s)   (all certs EXCEPT the last)
#       root.crt           = last cert only           (root CA)
#   The key-modulus check matches the private key against the FIRST cert (= leaf).
#   Names (lib/epas-ssl.sh): the leaf must be valid for THIS server (SSL_HOST_NAME, else hostname -f/-s/IPs)
#   and for every name in SSL_SHARED_NAMES (VIP / DNS alias) - otherwise nothing is changed. A certificate
#   that is also valid for another node (shared) or a wildcard only warns.
#
# Safety:
#   - Everything is built and checked in a private temp directory first; a failed check changes nothing.
#   - Files are replaced atomically (temp file in the same directory + mv); a symbolic link where a
#     file should be is refused, never written through.
#   - The passphrase never appears on a command line (openssl reads it with -passin file:).
#   - Replaced files are backed up to SECURITY_TOP/.backup-<timestamp>; if EPAS does not come back
#     after the restart, they are restored automatically.
# -----------------------------------------------------------------------------

# --- 1. Parse args (shared start-up: lib/common.sh) ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/epas-detect.sh
source "${SCRIPT_DIR}/../../lib/epas-detect.sh"
# shellcheck source=../../lib/epas-ssl.sh
source "${SCRIPT_DIR}/../../lib/epas-ssl.sh"

INPUT_PEM_BUNDLE=""
PASS_FILE_ARG="" SEC_TOP_ARG="" FORCE_RESTART=0 NAMES_WARN=0 NO_HBA=0
usage() {
    cat <<USAGE
Usage: $0 [--env conf/site.env] [-b|--bundle /path/to/bundle.pem] [--yes]
          [--restart] [--passphrase-file FILE] [--security-top DIR] [--names-warn] [--no-hba]
Run as SYSTEM_USER (e.g.: sudo -iu enterprisedb $0 -b bundle.pem), never as root.
Installs an ENCRYPTED key + certificate chain for EPAS in SECURITY_TOP (default /etc/edb/ssl):
server.key, server_chained.crt, root.crt, passphrase file + helper; writes conf.d/ssl.conf and the
SSL block of pg_hba.conf; validates the config, then restarts the cluster (sudo systemctl restart
<unit> via conf/sudoers.d/epas-automation, or pg_ctl). Replaced files are backed up to
SECURITY_TOP/.backup-<timestamp> and restored automatically if EPAS does not take them.
A running cluster is RELOADED (no downtime) and checked; a stopped one is started.
  --restart            restart instead of reload (systemd via sudoers, or pg_ctl)
  --passphrase-file F  read the key passphrase from F instead of asking (automation)
  --security-top DIR   install into DIR instead of SECURITY_TOP from the config
  --names-warn         certificate name problems only warn (moving an EXISTING certificate)
  --no-hba             leave pg_hba.conf alone (no SSL rule block)
Bundle order: server cert -> intermediates -> root CA -> PRIVATE KEY (a key placed before the server cert is accepted too).
One-time root steps: SECURITY_TOP owned by SYSTEM_USER mode 0700 (epas-base-build-root.sh), sudoers file.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--bundle) [[ -n "${2:-}" ]] || die "$1 needs a file path"; INPUT_PEM_BUNDLE="$2"; shift 2 ;;
        --passphrase-file) [[ -n "${2:-}" ]] || die "$1 needs a file path"; PASS_FILE_ARG="$2"; shift 2 ;;
        --security-top) [[ -n "${2:-}" ]] || die "$1 needs a directory"; SEC_TOP_ARG="$2"; shift 2 ;;
        --restart)   FORCE_RESTART=1; shift ;;
        --names-warn) NAMES_WARN=1; shift ;;
        --no-hba)    NO_HBA=1; shift ;;
        -h|--help)   usage ;;
        *)           die "Unknown option: $1 (see --help)" ;;
    esac
done

# --- 2. Load & validate config (nothing below changes the host until the confirmation) ---
load_env required
SECURITY_TOP="${SECURITY_TOP:-/etc/edb/ssl}"
[[ -z "$SEC_TOP_ARG" ]] || SECURITY_TOP="$SEC_TOP_ARG"
require_vars DATA_TOP SECURITY_TOP SYSTEM_USER SERVICE_NAME PRIMARY_PORT PRIMARY_HOST STANDBY_HOST SUBNET_CIDR BINARY_TOP

ME="$(id -un)"
[ "$(id -u)" -ne 0 ] || die "Run this as the database OS user, not root:  sudo -iu ${SYSTEM_USER} $0 ...  (root writing into ${SYSTEM_USER}'s directories is unsafe; the restart goes through sudoers)"
[[ "$ME" == "$SYSTEM_USER" ]] || die "Run as SYSTEM_USER '${SYSTEM_USER}', not '${ME}':  sudo -iu ${SYSTEM_USER} $0 ..."

DATA_TOP="${DATA_TOP%/}"
SECURITY_TOP="${SECURITY_TOP%/}"
[[ "$SECURITY_TOP" == /* && "$SECURITY_TOP" =~ ^[A-Za-z0-9._/-]+$ && "$SECURITY_TOP" != *..* ]] \
    || die "Invalid SECURITY_TOP '${SECURITY_TOP}': absolute path, letters/digits and . _ - / only"
[[ -f "${DATA_TOP}/PG_VERSION" ]] || die "${DATA_TOP} is not an EPAS cluster (no PG_VERSION)"
[[ -O "$DATA_TOP" ]] || die "${DATA_TOP} is owned by $(stat -c %U "$DATA_TOP"), not ${ME}"
for d in "$DATA_TOP" "${DATA_TOP}/conf.d" "$SECURITY_TOP"; do
    [[ ! -L "$d" ]] || die "Refusing to use ${d}: it is a symbolic link"
done

# SECURITY_TOP: outside PGDATA (recommended, created once by root) or the old layout inside PGDATA
SSL_IN_PGDATA=0
case "$(readlink -m "$SECURITY_TOP")/" in "$(readlink -m "$DATA_TOP")"/*) SSL_IN_PGDATA=1 ;; esac
if [[ -d "$SECURITY_TOP" ]]; then
    [[ -O "$SECURITY_TOP" ]] \
        || die "${SECURITY_TOP} is owned by $(stat -c %U "$SECURITY_TOP"), not ${ME}. One-time root fix: sudo chown ${SYSTEM_USER}:${SYSTEM_GROUP} ${SECURITY_TOP} && sudo chmod 0700 ${SECURITY_TOP}"
elif (( ! SSL_IN_PGDATA )); then
    die "${SECURITY_TOP} does not exist. One-time root step (epas-base-build-root.sh does it too): sudo install -d -o ${SYSTEM_USER} -g ${SYSTEM_GROUP} -m 0700 ${SECURITY_TOP}"
fi
if (( SSL_IN_PGDATA )); then
    log_warn "SECURITY_TOP ${SECURITY_TOP} is inside PGDATA (old layout): pg_basebackup, standby rebuilds and backups copy this host's SSL key AND passphrase. Recommended: SECURITY_TOP=/etc/edb/ssl"
fi

# --- 3. Bundle path -----------------------------------------------------------
if [[ -z "$INPUT_PEM_BUNDLE" ]]; then
    read -r -p "Enter full path to PEM bundle: " INPUT_PEM_BUNDLE
fi
[[ -f "$INPUT_PEM_BUNDLE" ]] || die "Bundle not found: $INPUT_PEM_BUNDLE"
[[ -r "$INPUT_PEM_BUNDLE" ]] \
    || die "${INPUT_PEM_BUNDLE} is not readable by ${ME}. Hand it over first, e.g.: sudo install -o ${SYSTEM_USER} -m 0600 ${INPUT_PEM_BUNDLE} /tmp/epas_bundle.pem"

# --- 4. How the new settings will be applied (checked before anything changes) ----
#   running cluster          -> reload (pg_ctl reload = SIGHUP: no downtime, no sudo)
#   stopped, or --restart    -> (re)start: systemd via sudoers, else pg_ctl
PG_CTL="${BINARY_TOP}/bin/pg_ctl"
[[ -x "$PG_CTL" ]] || die "pg_ctl not found at ${PG_CTL}"
UNIT=""
RUNNING=0
MGR="$(epas_manager "$DATA_TOP")"
case "$MGR" in
    systemd:*) CTL=systemd; UNIT="${MGR#systemd:}"; RUNNING=1 ;;
    pg_ctl)    CTL=pg_ctl; RUNNING=1 ;;
    stopped)   if epas_unit_loaded "$SERVICE_NAME"; then CTL=systemd; UNIT="$SERVICE_NAME"; else CTL=pg_ctl; fi ;;
    *)         die "Cannot tell whether ${DATA_TOP} is running (epas_manager: ${MGR})" ;;
esac
UNIT="${UNIT%.service}"     # short form, as listed in conf/sudoers.d/epas-automation
if (( RUNNING && ! FORCE_RESTART )); then
    APPLY=reload
    RESTART_HOW="reload (pg_ctl reload - no downtime)"
elif [[ "$CTL" == systemd ]]; then
    APPLY=restart
    command -v sudo >/dev/null 2>&1 || die "sudo is not installed - needed for: systemctl restart ${UNIT}"
    sudo -n -l systemctl restart "$UNIT" >/dev/null 2>&1 \
        || die "${ME} may not run 'sudo systemctl restart ${UNIT}' without a password. One-time root step: sudo install -m 0440 ${TOOLKIT_ROOT}/conf/sudoers.d/epas-automation /etc/sudoers.d/epas-automation && sudo visudo -c"
    RESTART_HOW="sudo systemctl restart ${UNIT}"
else
    APPLY=restart
    RESTART_HOW="pg_ctl restart (cluster is not run by systemd)"
fi
if [[ -n "$PASS_FILE_ARG" ]]; then
    [[ -f "$PASS_FILE_ARG" && -r "$PASS_FILE_ARG" ]] || die "Passphrase file not readable: ${PASS_FILE_ARG}"
fi

echo "Expected bundle order: server cert -> intermediates -> root CA -> PRIVATE KEY (key first is accepted too)."
show_config SERVICE_NAME SYSTEM_USER DATA_TOP SECURITY_TOP PRIMARY_PORT STANDBY_HOST SUBNET_CIDR SSL_SHARED_NAMES SSL_HOST_NAME INPUT_PEM_BUNDLE RESTART_HOW
confirm_or_exit "install SSL from ${INPUT_PEM_BUNDLE} into ${SECURITY_TOP}, REPLACE ${DATA_TOP}/conf.d/ssl.conf and the SSL block of ${DATA_TOP}/pg_hba.conf (backed up first), then restart: ${RESTART_HOW}"

# --- 5. Private work area (mode 0700): everything is built and checked here first ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# put_file SRC DEST MODE - replace DEST atomically: temp file in DEST's directory, then mv.
# Never writes through a symbolic link.
put_file() {
    local src=$1 dest=$2 mode=$3 tmp
    [[ ! -L "$dest" ]] || die "Refusing to write ${dest}: it is a symbolic link"
    [[ ! -e "$dest" || -f "$dest" ]] || die "Refusing to write ${dest}: not a regular file"
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")"
    cat "$src" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
}

# --- 6. Extract private key & ENFORCE position + encryption -------------------
echo "Extracting private key from bundle..."
awk '/-BEGIN .*PRIVATE KEY-/,/-END .*PRIVATE KEY-/' "$INPUT_PEM_BUNDLE" > "${WORK}/server.key"
[[ -s "${WORK}/server.key" ]] || die "No private key found in bundle."

# Order check: the key block sits at one end of the bundle - after the last certificate (recommended)
# or before the first one (older layout) - never between certificates (lib/epas-ssl.sh).
ORDER_OUT="$(epas_ssl_bundle_order "$INPUT_PEM_BUNDLE")" \
    || die "Bundle order violation - ${ORDER_OUT}. Required order: server cert -> intermediates -> root CA -> private key."
echo "Bundle layout: ${ORDER_OUT}"

# Not a secret: a deliberately wrong passphrase. An unencrypted key opens with it.
if openssl pkey -in "${WORK}/server.key" -noout -passin pass:_DUMMY_INVALID_ 2>/dev/null; then
    die "Private key is NOT encrypted. This script requires an encrypted key."
fi

# --- 7. Passphrase (mandatory, validated; kept in a 0600 file, never on a command line) ---
if [[ -n "$PASS_FILE_ARG" ]]; then
    IFS= read -r KEY_PASS < "$PASS_FILE_ARG" || true
    printf '%s' "$KEY_PASS" > "${WORK}/pass"
    openssl pkey -in "${WORK}/server.key" -passin file:"${WORK}/pass" -noout 2>/dev/null \
        || die "The passphrase in ${PASS_FILE_ARG} does not open the private key. Nothing was changed."
fi
while [[ -z "$PASS_FILE_ARG" ]]; do
    read -s -r -p "Enter server.key decryption passphrase: " KEY_PASS
    echo
    [[ -n "$KEY_PASS" ]] || { echo "Passphrase cannot be empty. Try again."; continue; }
    printf '%s' "$KEY_PASS" > "${WORK}/pass"
    if openssl pkey -in "${WORK}/server.key" -passin file:"${WORK}/pass" -noout 2>/dev/null; then
        break
    fi
    echo "Incorrect passphrase. Try again."
done
KEY_PASS=""

PASSPHRASE_FILE="${SECURITY_TOP}/.ssl_key_passphrase"
PASSPHRASE_CMD="${SECURITY_TOP}/read_passphrase.sh"
cat > "${WORK}/read_passphrase.sh" <<EOF
#!/bin/sh
exec cat '${PASSPHRASE_FILE}'
EOF

# --- 8. Extract certificates ----------------------------------------------------
# With the enforced order (leaf FIRST, root LAST):
#   server_chained.crt = every cert EXCEPT the last  (leaf + intermediates)
#   root.crt           = the last cert only          (root CA)
echo "Extracting certificates..."
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$INPUT_PEM_BUNDLE" || true)
if [[ "$CERT_COUNT" -le 1 ]]; then
    # Single/self-signed: chained = the one cert, root = same cert
    awk '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/' "$INPUT_PEM_BUNDLE" > "${WORK}/server_chained.crt"
    cp "${WORK}/server_chained.crt" "${WORK}/root.crt"
else
    awk -v total="$CERT_COUNT" '
        /-BEGIN CERTIFICATE-/ { n++; skip = (n == total) }
        skip { next }
        { print }
    ' "$INPUT_PEM_BUNDLE" > "${WORK}/server_chained.crt"
    awk '/-BEGIN CERTIFICATE-/{buf=""; keep=1} keep{buf=buf $0 ORS} /-END CERTIFICATE-/{keep=0} END{printf "%s", buf}' \
        "$INPUT_PEM_BUNDLE" > "${WORK}/root.crt"
fi
[[ -s "${WORK}/server_chained.crt" ]] || die "server_chained.crt is empty"
[[ -s "${WORK}/root.crt" ]]           || die "root.crt is empty"

# --- 9. Preflight checks (on the new files, before anything is installed) -------
echo "Running preflight checks..."
# Match key against the FIRST cert in the chain (the leaf) - valid only because the order is enforced.
if openssl rsa -in "${WORK}/server.key" -passin file:"${WORK}/pass" -noout 2>/dev/null; then
    KEY_MOD=$(openssl rsa -in "${WORK}/server.key" -passin file:"${WORK}/pass" -noout -modulus 2>/dev/null | md5sum | awk '{print $1}')
    CERT_MOD=$(openssl x509 -in "${WORK}/server_chained.crt" -noout -modulus 2>/dev/null | md5sum | awk '{print $1}')
    [[ "$KEY_MOD" == "$CERT_MOD" ]] || die "Private key does not match certificate (leaf)"
else
    echo "Skipping RSA modulus check (non-RSA key)"
fi
openssl x509 -in "${WORK}/server_chained.crt" -noout -checkend 0 >/dev/null 2>&1 || die "Certificate is expired"
VERIFY_OUT=$(openssl verify -partial_chain -CAfile "${WORK}/root.crt" "${WORK}/server_chained.crt" 2>&1 || true)
echo "Chain verify: ${VERIFY_OUT/#${WORK}\//}"
# Names: the certificate must be valid for THIS server and for every name in SSL_SHARED_NAMES
# (VIP / DNS alias). A certificate shared with other servers, or a wildcard, only warns.
echo "Certificate names: $(epas_ssl_san "${WORK}/server_chained.crt" | paste -sd' ' -)"
NAME_RC=0
NAME_REPORT="$(epas_ssl_check_names "${WORK}/server_chained.crt")" || NAME_RC=$?
while IFS= read -r line; do
    case "$line" in
        ERROR*) log_error "${line#ERROR }" ;;
        WARN*)  log_warn "${line#WARN  }" ;;
        ?*)     echo "$line" ;;
    esac
done <<< "$NAME_REPORT"
if (( NAME_RC != 0 )); then
    (( NAMES_WARN )) || die "This certificate does not fit this server (see above). Nothing was changed."
    log_warn "--names-warn: continuing despite the name problems above (an existing certificate is being moved; fix them at the next renewal)"
fi
echo "Preflight checks passed."

# --- 10. New ssl.conf and pg_hba.conf, built in the work area -------------------
CUSTOM_SSL_CONF="${DATA_TOP}/conf.d/ssl.conf"
cat > "${WORK}/ssl.conf" <<EOF
# Managed by edb_toolkit modules/02-ssl/epas-ssl-setup.sh - re-running replaces this file.
ssl = on
ssl_cert_file = '${SECURITY_TOP}/server_chained.crt'
ssl_key_file = '${SECURITY_TOP}/server.key'
ssl_ca_file = '${SECURITY_TOP}/root.crt'
ssl_passphrase_command = '${PASSPHRASE_CMD}'
ssl_passphrase_command_supports_reload = on     # lets a reload (no restart) load a renewed, encrypted key

ssl_min_protocol_version = 'TLSv1.2'
ssl_ciphers = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384'
ssl_prefer_server_ciphers = on
EOF

# The SSL rules live in a marked block at the TOP of pg_hba.conf (first match wins); every
# existing rule is kept below it. Re-running replaces only the marked block.
PG_HBA_CONF="${DATA_TOP}/pg_hba.conf"
HBA_BEGIN="# >>> edb_toolkit SSL rules (managed by epas-ssl-setup.sh - edits inside this block are replaced) >>>"
HBA_END="# <<< edb_toolkit SSL rules <<<"
{
    echo "$HBA_BEGIN"
    cat <<EOF
# Local connections
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Standby / replication (SSL only)
hostssl replication     all             ${STANDBY_HOST}/32      scram-sha-256
hostssl all             all             ${STANDBY_HOST}/32      scram-sha-256
hostnossl replication   all             ${SUBNET_CIDR}          reject

# Subnet-wide SSL enforcement
hostssl all             all             ${SUBNET_CIDR}          scram-sha-256
hostnossl all           all             ${SUBNET_CIDR}          reject
EOF
    echo "$HBA_END"
    echo ""
    # existing rules, minus any previous managed block
    if [[ -f "$PG_HBA_CONF" ]]; then
        awk -v b="$HBA_BEGIN" -v e="$HBA_END" '$0==b{skip=1; next} $0==e{skip=0; getline nl; if (nl!="") print nl; next} !skip{print}' "$PG_HBA_CONF"
    fi
} > "${WORK}/pg_hba.conf"

PG_CONF="${DATA_TOP}/postgresql.conf"
[[ ! -L "$PG_CONF" ]] || die "Refusing to use ${PG_CONF}: it is a symbolic link"
ADD_INCLUDE=0
grep -qE "^include_dir\s*=\s*['\"]conf.d['\"]" "$PG_CONF" 2>/dev/null || ADD_INCLUDE=1

# Every target must be a plain file (or absent) BEFORE the first one is replaced
for f in "${SECURITY_TOP}/server.key" "${SECURITY_TOP}/.ssl_key_passphrase" "${SECURITY_TOP}/read_passphrase.sh" \
         "${SECURITY_TOP}/server_chained.crt" "${SECURITY_TOP}/root.crt" "$CUSTOM_SSL_CONF" "$PG_HBA_CONF"; do
    [[ ! -L "$f" ]] || die "Refusing to write ${f}: it is a symbolic link. Nothing was changed."
    [[ ! -e "$f" || -f "$f" ]] || die "Refusing to write ${f}: not a regular file. Nothing was changed."
done

# --- 11. Install: back up, then replace each file atomically ----------------------
[[ -d "$SECURITY_TOP" ]] || mkdir -m 0700 "$SECURITY_TOP"      # old layout inside PGDATA only
chmod 0700 "$SECURITY_TOP"
mkdir -p "${DATA_TOP}/conf.d"

BACKUP_DIR="$(mktemp -d "${SECURITY_TOP}/.backup-$(date +%Y%m%d%H%M%S)-XXXX")"     # unique even for two runs in one second

BACKED_UP=()   # files that existed and were saved (restored on rollback)
CREATED=()     # files that did not exist before (moved aside on rollback)
backup() {
    local target="$1"
    if [[ -e "$target" ]]; then
        mkdir -p "${BACKUP_DIR}$(dirname "$target")"
        cp -a "$target" "${BACKUP_DIR}${target}"
        BACKED_UP+=("$target")
    else
        CREATED+=("$target")
    fi
}
# restore_file BACKUP DEST - put a saved copy back (atomic; works on read-only 0400/0500 files)
restore_file() {
    local bak=$1 dest=$2 tmp
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")"
    cp -p "$bak" "$tmp"
    mv -f "$tmp" "$dest"
}
rollback() {
    local f failed="${BACKUP_DIR}/failed-new-files"
    mkdir -p "$failed"
    for f in "${BACKED_UP[@]+"${BACKED_UP[@]}"}"; do
        [[ -e "$f" ]] && cp -a "$f" "${failed}/$(basename "$f")" 2>/dev/null || true
        restore_file "${BACKUP_DIR}${f}" "$f"
        log_warn "Restored previous ${f}"
    done
    for f in "${CREATED[@]+"${CREATED[@]}"}"; do
        if [[ "$f" == "$CUSTOM_SSL_CONF" && -e "$f" ]]; then
            mv "$f" "${failed}/$(basename "$f")"
            log_warn "Removed new ${f} (did not exist before)"
        fi
    done
    log_warn "Failed new files kept in ${failed} for diagnosis."
}

backup "${SECURITY_TOP}/server.key";         put_file "${WORK}/server.key"          "${SECURITY_TOP}/server.key"         0600
backup "$PASSPHRASE_FILE";                   put_file "${WORK}/pass"                "$PASSPHRASE_FILE"                   0400
backup "$PASSPHRASE_CMD";                    put_file "${WORK}/read_passphrase.sh"  "$PASSPHRASE_CMD"                    0500
backup "${SECURITY_TOP}/server_chained.crt"; put_file "${WORK}/server_chained.crt"  "${SECURITY_TOP}/server_chained.crt" 0644
backup "${SECURITY_TOP}/root.crt";           put_file "${WORK}/root.crt"            "${SECURITY_TOP}/root.crt"           0644
backup "$CUSTOM_SSL_CONF";                   put_file "${WORK}/ssl.conf"            "$CUSTOM_SSL_CONF"                   0644
if (( ! NO_HBA )); then
    backup "$PG_HBA_CONF";                   put_file "${WORK}/pg_hba.conf"         "$PG_HBA_CONF"                       0600
fi
if (( ADD_INCLUDE )); then
    echo "Adding include_dir to ${PG_CONF}..."
    backup "$PG_CONF"
    cp -p "$PG_CONF" "${WORK}/postgresql.conf"
    echo "include_dir = 'conf.d'" >> "${WORK}/postgresql.conf"
    put_file "${WORK}/postgresql.conf" "$PG_CONF" 0600
fi

# --- 12. Validate config, then reload or restart ---------------------------------------------------
# Real check: ask the EPAS binary to parse the configuration (it fails on any invalid setting).
echo "Validating configuration..."
PG_BIN="${BINARY_TOP}/bin/edb-postgres"; [[ -x "$PG_BIN" ]] || PG_BIN="${BINARY_TOP}/bin/postgres"
if [[ -x "$PG_BIN" ]]; then
    if CHECK_OUT=$("$PG_BIN" -D "$DATA_TOP" -C ssl_cert_file 2>&1); then
        echo "Configuration parses OK (ssl_cert_file = ${CHECK_OUT})"
    else
        log_error "EPAS rejected the new configuration - NOT restarting (the running server is unaffected):"
        echo "$CHECK_OUT" | tail -5
        rollback
        die "New files rolled back. Fix the problem and re-run; details in ${BACKUP_DIR}"
    fi
else
    log_warn "EPAS binary not found in ${BINARY_TOP}/bin - skipping configuration check."
fi

PSQL="${BINARY_TOP}/bin/psql"; [[ -x "$PSQL" ]] || PSQL="psql"
SOCK="$(epas_conf_get "$DATA_TOP" unix_socket_directories)"; SOCK="${SOCK%%,*}"; SOCK="${SOCK//[[:space:]\'\"]/}"
HOST_ARGS=(); [[ "$SOCK" == /* ]] && HOST_ARGS=(-h "$SOCK")
live_port() { local p; p="$(epas_port "$DATA_TOP" | cut -f1)"; echo "${p:-$PRIMARY_PORT}"; }
psql_q() { "$PSQL" -X "${HOST_ARGS[@]+"${HOST_ARGS[@]}"}" -p "$(live_port)" -d postgres -Atc "$1" 2>/dev/null; }
# SHA-256 fingerprint of the certificate the server presents on 127.0.0.1 ('' if it cannot be read)
served_fp() {
    openssl s_client -starttls postgres -connect "127.0.0.1:$(live_port)" </dev/null 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
}
NEW_FP="$(openssl x509 -in "${SECURITY_TOP}/server_chained.crt" -noout -fingerprint -sha256 | cut -d= -f2)"

reload_ok() {
    local errs fp
    "$PG_CTL" -D "$DATA_TOP" reload >/dev/null 2>&1 || { log_error "pg_ctl reload failed"; return 1; }
    sleep 2
    errs="$(psql_q "SELECT (SELECT count(*) FROM pg_file_settings WHERE error IS NOT NULL) + (SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL)")" \
        || { log_error "Cannot connect to EPAS after the reload"; return 1; }
    if [[ "$errs" != 0 ]]; then
        log_error "EPAS reports ${errs} configuration error(s) after the reload: SELECT * FROM pg_file_settings WHERE error IS NOT NULL; SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;"
        return 1
    fi
    fp="$(served_fp)"
    if [[ -z "$fp" ]]; then
        log_warn "Could not read the certificate the server presents on 127.0.0.1:$(live_port) (no TCP listener there?) - the reload is not verified by fingerprint; check with a client"
        return 0
    fi
    if [[ "$fp" != "$NEW_FP" ]]; then
        log_error "After the reload the server still presents the PREVIOUS certificate: the new key/certificate was not loaded (see the server log)"
        return 1
    fi
    echo "The server now presents the new certificate (SHA-256 ${fp})"
}
restart_ok() {
    if [[ "$CTL" == systemd ]]; then
        sudo -n systemctl restart "$UNIT" && sleep 3 && systemctl is-active --quiet "$UNIT"
    else
        "$PG_CTL" -D "$DATA_TOP" -m fast -w -t 60 -l "${DATA_TOP}/pg_ctl_startup.log" restart >/dev/null
    fi
}

if [[ "$APPLY" == reload ]]; then
    echo "Applying: ${RESTART_HOW}..."
    if ! reload_ok; then
        log_error "EPAS (${DATA_TOP}) did not take the new SSL configuration - rolling back."
        rollback
        "$PG_CTL" -D "$DATA_TOP" reload >/dev/null 2>&1 || true
        log_audit "SSL setup rolled back for ${DATA_TOP}: reload of the new configuration failed; previous files restored and reloaded"
        die "Rolled back: EPAS kept running throughout and uses the PREVIOUS configuration again. Check the server log and ${BACKUP_DIR}/failed-new-files."
    fi
else
    echo "Applying: ${RESTART_HOW}..."
    if ! restart_ok; then
        log_error "EPAS (${DATA_TOP}) did not start with the new SSL configuration - rolling back."
        rollback
        if restart_ok; then
            log_audit "SSL setup rolled back for ${DATA_TOP}: new configuration failed to start; previous files restored"
            die "Rolled back: EPAS is running again with the PREVIOUS configuration. Check the server log (and 'journalctl -u ${UNIT:-$SERVICE_NAME}') and the files in ${BACKUP_DIR}/failed-new-files."
        else
            die "Rollback restart ALSO failed - EPAS (${DATA_TOP}) is DOWN. Investigate now: server log, journalctl -u ${UNIT:-$SERVICE_NAME}; backups in ${BACKUP_DIR}"
        fi
    fi
fi

# --- 13. Final check -------------------------------------------------------------------
SSL_STATUS="$(psql_q "SHOW ssl;" || true)"
[[ "$SSL_STATUS" == "on" ]] && echo "SSL is active (ssl = on)" || echo "WARNING: Could not confirm SSL via psql"

log_audit "SSL installed for ${DATA_TOP}: bundle ${INPUT_PEM_BUNDLE} (${CERT_COUNT} certs), files in ${SECURITY_TOP}, backup ${BACKUP_DIR}"

# --- 14. Summary ----------------------------------------------------------------------
cat <<EOF

===============================================================================
EPAS SSL Setup Complete  (Encrypted Key + File Passphrase + Full Chain)
===============================================================================
Backup dir          : $BACKUP_DIR
Encrypted key       : ${SECURITY_TOP}/server.key
Passphrase file     : ${PASSPHRASE_FILE}   (0400 ${SYSTEM_USER})
Helper script       : ${PASSPHRASE_CMD}
Server chain (leaf + intermediates): ${SECURITY_TOP}/server_chained.crt  (${CERT_COUNT} cert(s) in bundle)
Root CA             : ${SECURITY_TOP}/root.crt
SSL config          : $CUSTOM_SSL_CONF
HBA config          : $PG_HBA_CONF
Applied with        : ${RESTART_HOW}
===============================================================================
EOF
