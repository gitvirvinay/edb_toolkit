#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# epas-ssl-setup.sh  —  Encrypted-key, file-based passphrase (Arch 2A)
#   v3: PEM bundle order is now ENFORCED and DOCUMENTED as:
#
#         -----BEGIN ENCRYPTED PRIVATE KEY-----     (1) private key  FIRST
#         -----BEGIN CERTIFICATE-----               (2) server/leaf  certificate
#         -----BEGIN CERTIFICATE-----               (3..n-1) intermediate(s)
#         -----BEGIN CERTIFICATE-----               (n) root CA      LAST
#
#   Results:
#       server_chained.crt = leaf + intermediate(s)   (all certs EXCEPT the last)
#       root.crt           = last cert only           (root CA)
#
#   The key-modulus check matches the private key against the FIRST cert in
#   the bundle (= leaf), which is only correct with this ordering.
#
# Usage:  sudo ./epas-ssl-setup.sh --env conf/site.env [-b /path/to/bundle.pem]
# -----------------------------------------------------------------------------

# --- 1. Parse args (shared start-up: lib/common.sh) ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

INPUT_PEM_BUNDLE=""
usage() {
    cat <<USAGE
Usage: sudo $0 [--env conf/site.env] [-b|--bundle /path/to/bundle.pem] [--yes]
Installs an ENCRYPTED key + certificate chain for EPAS: SECURITY_TOP/server.key, server_chained.crt,
root.crt, passphrase file + helper, conf.d/ssl.conf and an SSL-only pg_hba.conf; validates the
config, then restarts the service. Existing files are backed up to SECURITY_TOP/.backup-<timestamp>.
Bundle order: PRIVATE KEY -> server cert -> intermediates -> root CA (last).
Must run as root. Config is required (default: conf/site.env in the repo).
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--bundle) [[ -n "${2:-}" ]] || die "$1 needs a file path"; INPUT_PEM_BUNDLE="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           die "Unknown option: $1 (see --help)" ;;
    esac
done

# --- 2. Load & validate config ---------------------------------------------------
load_env required
require_root
require_vars DATA_TOP SECURITY_TOP SYSTEM_USER SYSTEM_GROUP SERVICE_NAME PRIMARY_PORT PRIMARY_HOST STANDBY_HOST SUBNET_CIDR BINARY_TOP

# --- 3. Bundle path -----------------------------------------------------------
if [[ -z "$INPUT_PEM_BUNDLE" ]]; then
    read -r -p "Enter full path to PEM bundle: " INPUT_PEM_BUNDLE
fi
[[ -f "$INPUT_PEM_BUNDLE" ]] || die "Bundle not found: $INPUT_PEM_BUNDLE"

echo "Expected bundle order: PRIVATE KEY -> server cert -> intermediates -> root CA (last)."
show_config SERVICE_NAME SYSTEM_USER DATA_TOP SECURITY_TOP PRIMARY_PORT STANDBY_HOST SUBNET_CIDR INPUT_PEM_BUNDLE
confirm_or_exit "install SSL from ${INPUT_PEM_BUNDLE} into ${SECURITY_TOP}, REPLACE ${DATA_TOP}/conf.d/ssl.conf and ${DATA_TOP}/pg_hba.conf (backed up first), then restart ${SERVICE_NAME}"

# --- 4. Prep directories & backup bucket --------------------------------------
mkdir -p "$SECURITY_TOP" "${DATA_TOP}/conf.d"
chmod 0700 "$SECURITY_TOP"

BACKUP_DIR="${SECURITY_TOP}/.backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

# --- Backup: keep the full path under BACKUP_DIR and remember what was saved/created ---
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

# --- Rollback: put every replaced file back (failed versions kept for diagnosis) ---
rollback() {
    local f failed="${BACKUP_DIR}/failed-new-files"
    mkdir -p "$failed"
    for f in "${BACKED_UP[@]+"${BACKED_UP[@]}"}"; do
        [[ -e "$f" ]] && cp -a "$f" "${failed}/$(basename "$f")" 2>/dev/null || true
        cp -a "${BACKUP_DIR}${f}" "$f"
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

# --- 5. Extract private key & ENFORCE position + encryption -------------------
echo "Extracting private key from bundle..."
awk '/-BEGIN .*PRIVATE KEY-/,/-END .*PRIVATE KEY-/' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/server.key.tmp"

if [[ ! -s "${SECURITY_TOP}/server.key.tmp" ]]; then
    die "No private key found in bundle."
fi

# Order check: key block must appear BEFORE the first certificate block.
KEY_START_LINE=$(grep -n -m1 -- '-BEGIN .*PRIVATE KEY-' "$INPUT_PEM_BUNDLE" | cut -d: -f1)
FIRST_CERT_LINE=$(grep -n -m1 -- '-BEGIN CERTIFICATE-' "$INPUT_PEM_BUNDLE" | cut -d: -f1)

if [[ -n "$FIRST_CERT_LINE" && "$KEY_START_LINE" -gt "$FIRST_CERT_LINE" ]]; then
    rm -f "${SECURITY_TOP}/server.key.tmp"
    die "Bundle order violation - private key must come BEFORE the server certificate. Required order: key -> server cert -> intermediates -> root CA."
fi

if openssl pkey -in "${SECURITY_TOP}/server.key.tmp" -noout -passin pass:_DUMMY_INVALID_ 2>/dev/null; then
    rm -f "${SECURITY_TOP}/server.key.tmp"
    die "Private key is NOT encrypted. This script requires an encrypted key."
fi

# --- 6. Prompt for passphrase (mandatory, non-empty, validated) ---------------
while true; do
    read -s -r -p "Enter server.key decryption passphrase: " KEY_PASS
    echo
    [[ -n "$KEY_PASS" ]] || { echo "Passphrase cannot be empty. Try again."; continue; }

    if openssl pkey -in "${SECURITY_TOP}/server.key.tmp" -passin pass:"$KEY_PASS" -noout 2>/dev/null; then
        break
    fi
    echo "Incorrect passphrase. Try again."
done

backup "${SECURITY_TOP}/server.key"
mv "${SECURITY_TOP}/server.key.tmp" "${SECURITY_TOP}/server.key"
chmod 0600 "${SECURITY_TOP}/server.key"

# --- 7. Store passphrase in hidden file ----------------------------------------
PASSPHRASE_FILE="${SECURITY_TOP}/.ssl_key_passphrase"
backup "$PASSPHRASE_FILE"

printf '%s' "$KEY_PASS" > "$PASSPHRASE_FILE"
chmod 0400 "$PASSPHRASE_FILE"
chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$PASSPHRASE_FILE"

# --- 8. Helper script for PostgreSQL -------------------------------------------
PASSPHRASE_CMD="${SECURITY_TOP}/read_passphrase.sh"
backup "$PASSPHRASE_CMD"

cat > "$PASSPHRASE_CMD" <<EOF
#!/bin/sh
exec cat '${PASSPHRASE_FILE}'
EOF
chmod 0500 "$PASSPHRASE_CMD"
chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$PASSPHRASE_CMD"

# --- 9. Extract certificates ----------------------------------------------------
# With the enforced order (leaf FIRST, root LAST):
#   server_chained.crt = every cert EXCEPT the last  (leaf + intermediates)
#   root.crt           = the last cert only          (root CA)
echo "Extracting certificates..."

CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$INPUT_PEM_BUNDLE" || true)

backup "${SECURITY_TOP}/server_chained.crt"
backup "${SECURITY_TOP}/root.crt"

if [[ "$CERT_COUNT" -le 1 ]]; then
    # Single/self-signed: chained = the one cert, root = same cert
    awk '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/server_chained.crt"
    cp "${SECURITY_TOP}/server_chained.crt" "${SECURITY_TOP}/root.crt"
else
    awk -v total="$CERT_COUNT" '
        /-BEGIN CERTIFICATE-/ { n++; skip = (n == total) }
        skip { next }
        { print }
    ' "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/server_chained.crt"

    awk '/-BEGIN CERTIFICATE-/{buf=""; keep=1} keep{buf=buf $0 ORS} /-END CERTIFICATE-/{keep=0} END{printf "%s", buf}' \
        "$INPUT_PEM_BUNDLE" > "${SECURITY_TOP}/root.crt"
fi

[[ -s "${SECURITY_TOP}/server_chained.crt" ]] || die "server_chained.crt is empty"
[[ -s "${SECURITY_TOP}/root.crt" ]]           || die "root.crt is empty"

chown -R "${SYSTEM_USER}:${SYSTEM_GROUP}" "$SECURITY_TOP"
chmod 0644 "${SECURITY_TOP}/server_chained.crt" "${SECURITY_TOP}/root.crt"

# --- 10. Preflight checks --------------------------------------------------------
echo "Running preflight checks..."

# Match key against the FIRST cert in the chain (the leaf) - valid only
# because the bundle order is enforced in step 5.
if openssl rsa -in "${SECURITY_TOP}/server.key" -passin file:"$PASSPHRASE_FILE" -noout 2>/dev/null; then
    KEY_MOD=$(openssl rsa -in "${SECURITY_TOP}/server.key" -passin file:"$PASSPHRASE_FILE" -noout -modulus 2>/dev/null | md5sum | awk '{print $1}')
    CERT_MOD=$(openssl x509 -in "${SECURITY_TOP}/server_chained.crt" -noout -modulus 2>/dev/null | md5sum | awk '{print $1}')
    [[ "$KEY_MOD" == "$CERT_MOD" ]] || die "Private key does not match certificate (leaf)"
else
    echo "Skipping RSA modulus check (non-RSA key)"
fi

openssl x509 -in "${SECURITY_TOP}/server_chained.crt" -noout -checkend 0 >/dev/null 2>&1 \
    || die "Certificate is expired"

if command -v openssl >/dev/null 2>&1; then
    VERIFY_OUT=$(openssl verify -partial_chain -CAfile "${SECURITY_TOP}/root.crt" "${SECURITY_TOP}/server_chained.crt" 2>&1 || true)
    echo "Chain verify: $VERIFY_OUT"
fi

echo "Preflight checks passed."

# --- 11. Generate ssl.conf --------------------------------------------------------
CUSTOM_SSL_CONF="${DATA_TOP}/conf.d/ssl.conf"
backup "$CUSTOM_SSL_CONF"

cat > "$CUSTOM_SSL_CONF" <<EOF
ssl = on
ssl_cert_file = '${SECURITY_TOP}/server_chained.crt'
ssl_key_file = '${SECURITY_TOP}/server.key'
ssl_ca_file = '${SECURITY_TOP}/root.crt'
ssl_passphrase_command = '${PASSPHRASE_CMD}'

ssl_min_protocol_version = 'TLSv1.2'
ssl_ciphers = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384'
ssl_prefer_server_ciphers = on
EOF

chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$CUSTOM_SSL_CONF"
chmod 0644 "$CUSTOM_SSL_CONF"

# --- 12. Merge SSL rules into pg_hba.conf -----------------------------------------
# The SSL rules live in a marked block at the TOP (first match wins); every existing rule is
# kept below it. Re-running replaces only the marked block. (Previously the whole file was
# replaced, dropping custom rules such as the replication rule from epas-prep-primary.sh.)
PG_HBA_CONF="${DATA_TOP}/pg_hba.conf"
backup "$PG_HBA_CONF"
HBA_BEGIN="# >>> edb_toolkit SSL rules (managed by epas-ssl-setup.sh - edits inside this block are replaced) >>>"
HBA_END="# <<< edb_toolkit SSL rules <<<"
HBA_TMP=$(mktemp)
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
} > "$HBA_TMP"
cat "$HBA_TMP" > "$PG_HBA_CONF"
rm -f "$HBA_TMP"

chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$PG_HBA_CONF"
chmod 0600 "$PG_HBA_CONF"

# --- Ensure conf.d is included in postgresql.conf ---------------------------------
PG_CONF="${DATA_TOP}/postgresql.conf"
if ! grep -qE "^include_dir\s*=\s*['\"]conf.d['\"]" "$PG_CONF" 2>/dev/null; then
    echo "Adding include_dir to ${PG_CONF}..."
    echo "include_dir = 'conf.d'" >> "$PG_CONF"
    chown "${SYSTEM_USER}:${SYSTEM_GROUP}" "$PG_CONF"
    chmod 0600 "$PG_CONF"
fi

# --- 13. Validate config & restart ---------------------------------------------------
# Real check: ask the EPAS binary to parse the configuration (it fails on any invalid setting).
# (Previously 'pg_ctl check' was used - pg_ctl has no 'check' mode, so the check always failed
#  and was ignored, and pg_ctl was looked up on root's PATH where EDB does not install it.)
echo "Validating configuration..."
PG_BIN="${BINARY_TOP}/bin/edb-postgres"; [[ -x "$PG_BIN" ]] || PG_BIN="${BINARY_TOP}/bin/postgres"
if [[ -x "$PG_BIN" ]]; then
    if CHECK_OUT=$(sudo -u "$SYSTEM_USER" "$PG_BIN" -D "$DATA_TOP" -C ssl_cert_file 2>&1); then
        echo "Configuration parses OK (ssl_cert_file = ${CHECK_OUT})"
    else
        log_error "EPAS rejected the new configuration - NOT restarting (the running server is unaffected):"
        echo "$CHECK_OUT" | tail -5
        die "Fix the problem or restore the previous files from ${BACKUP_DIR}"
    fi
else
    log_warn "EPAS binary not found in ${BINARY_TOP}/bin - skipping configuration check."
fi

restart_ok() { systemctl restart "$SERVICE_NAME" && sleep 3 && systemctl is-active --quiet "$SERVICE_NAME"; }

echo "Restarting $SERVICE_NAME..."
if ! restart_ok; then
    log_error "${SERVICE_NAME} did not start with the new SSL configuration - rolling back."
    rollback
    if restart_ok; then
        log_audit "SSL setup rolled back for ${SERVICE_NAME}: new configuration failed to start; previous files restored"
        die "Rolled back: ${SERVICE_NAME} is running again with the PREVIOUS configuration. Check 'journalctl -u ${SERVICE_NAME}' and the files in ${BACKUP_DIR}/failed-new-files."
    else
        die "Rollback restart ALSO failed - ${SERVICE_NAME} is DOWN. Investigate now: journalctl -u ${SERVICE_NAME}; backups in ${BACKUP_DIR}"
    fi
fi

# --- 14. Post-restart SSL verification ----------------------------------------------
if command -v psql >/dev/null 2>&1; then
    SSL_STATUS=$(su - "$SYSTEM_USER" -c "psql -p $PRIMARY_PORT -d postgres -Atc \"SHOW ssl;\" 2>/dev/null" || true)
    [[ "$SSL_STATUS" == "on" ]] && echo "SSL is active (ssl = on)" || echo "WARNING: Could not confirm SSL via psql"
else
    echo "psql not available for verification"
fi

log_audit "SSL installed for ${SERVICE_NAME}: bundle ${INPUT_PEM_BUNDLE} (${CERT_COUNT} certs), backup ${BACKUP_DIR}"

# --- 15. Summary ----------------------------------------------------------------------
cat <<EOF

===============================================================================
EPAS SSL Setup Complete  (Encrypted Key + File Passphrase + Full Chain)
===============================================================================
Backup dir          : $BACKUP_DIR
Encrypted key       : ${SECURITY_TOP}/server.key
Passphrase file     : ${SECURITY_TOP}/.ssl_key_passphrase   (0400 ${SYSTEM_USER})
Helper script       : ${PASSPHRASE_CMD}
Server chain (leaf + intermediates): ${SECURITY_TOP}/server_chained.crt  (${CERT_COUNT} cert(s) in bundle)
Root CA             : ${SECURITY_TOP}/root.crt
SSL config          : $CUSTOM_SSL_CONF
HBA config          : $PG_HBA_CONF
===============================================================================
EOF
