#!/usr/bin/env bash
# =============================================================================
# epas-ssl-relocate.sh - move a cluster's EXISTING SSL key/certificates out of PGDATA
#
#   epas-ssl-relocate.sh [--env conf/site.env] [--to DIR] [--remove-old] [--yes]
#     --to          target directory (default: SECURITY_TOP if it is outside DATA_TOP, else /etc/edb/ssl)
#     --remove-old  after a verified move, delete the old SSL files inside PGDATA (default: keep and list
#                   them; running it again later with --remove-old deletes the files recorded by the move)
#
# Run as SYSTEM_USER (e.g. enterprisedb). One-time root step first: the target directory, e.g.
#   sudo install -d -o enterprisedb -g enterprisedb -m 0700 /etc/edb/ssl
#
# Why: SSL files inside PGDATA are copied by pg_basebackup to every standby and land in every backup,
# and a major upgrade (new PGDATA) loses them. Outside PGDATA each host keeps its own.
#
# How: reads the cluster's EFFECTIVE SSL settings, collects its current key, certificate chain, CA file
# and passphrase (by running ssl_passphrase_command, as the server does), builds a bundle in a private
# temp directory and installs it with epas-ssl-setup.sh --security-top DIR: same checks, backups, reload
# (no downtime) and automatic rollback. The certificate itself does not change, so name problems only
# warn (--names-warn). An UNENCRYPTED key is encrypted on the way with a new random passphrase.
# Old backups still contain the old key: for production, plan to re-issue the certificate.
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/epas-detect.sh
source "${SCRIPT_DIR}/../../lib/epas-detect.sh"

TO_ARG="" REMOVE_OLD=0
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to)         [[ -n ${2:-} ]] || die "--to needs a directory"; TO_ARG=$2; shift 2 ;;
        --remove-old) REMOVE_OLD=1; shift ;;
        -h|--help)    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            die "Unknown option: $1 (see --help)" ;;
    esac
done
load_env required
require_vars DATA_TOP SYSTEM_USER
[ "$(id -u)" -ne 0 ] || die "Run as the database OS user, not root:  sudo -iu ${SYSTEM_USER} $0 ..."
[[ "$(id -un)" == "$SYSTEM_USER" ]] || die "Run as SYSTEM_USER '${SYSTEM_USER}':  sudo -iu ${SYSTEM_USER} $0 ..."
DATA_TOP="${DATA_TOP%/}"
[[ -f "${DATA_TOP}/PG_VERSION" ]] || die "${DATA_TOP} is not a cluster"

inside() { case "$(readlink -m "$1")/" in "$(readlink -m "$2")"/*) return 0 ;; esac; return 1; }
is_on()  { [[ ${1,,} =~ ^(on|true|yes|1)$ ]]; }

# --- Target ---
if [[ -n $TO_ARG ]]; then TO="${TO_ARG%/}"
elif [[ -n ${SECURITY_TOP:-} ]] && ! inside "$SECURITY_TOP" "$DATA_TOP"; then TO="${SECURITY_TOP%/}"
else TO=/etc/edb/ssl; fi
inside "$TO" "$DATA_TOP" && die "Target ${TO} is inside PGDATA - pick a directory outside it (default /etc/edb/ssl)"
[[ -d $TO && -O $TO ]] || die "${TO} must exist and belong to $(id -un). One-time root step: sudo install -d -o ${SYSTEM_USER} -g ${SYSTEM_GROUP:-$SYSTEM_USER} -m 0700 ${TO}"

# --- Current SSL settings ---
is_on "$(epas_conf_get "$DATA_TOP" ssl)" || { log_info "SSL is off in ${DATA_TOP} - nothing to move"; exit 0; }
abs() { [[ $1 == /* ]] && echo "$1" || echo "${DATA_TOP}/$1"; }
CERT="$(abs "$(epas_conf_get "$DATA_TOP" ssl_cert_file)")"; [[ $CERT != "${DATA_TOP}/" ]] || CERT="${DATA_TOP}/server.crt"
KEY="$(abs "$(epas_conf_get "$DATA_TOP" ssl_key_file)")";   [[ $KEY != "${DATA_TOP}/" ]]  || KEY="${DATA_TOP}/server.key"
CA="$(epas_conf_get "$DATA_TOP" ssl_ca_file)"; [[ -z $CA ]] || CA="$(abs "$CA")"
PCMD="$(epas_conf_get "$DATA_TOP" ssl_passphrase_command)"
MANIFEST="${TO}/.relocated-from-pgdata"      # old paths, written after a move; used by a later --remove-old
remove_old() {   # remove_old FILE... - delete old SSL files inside PGDATA and their now-empty directories
    local f d
    for f in "$@"; do
        inside "$f" "$DATA_TOP" || continue
        [[ -e $f ]] || continue
        rm -f -- "$f"; log_info "Removed ${f}"
    done
    for d in $(printf '%s\n' "$@" | xargs -n1 dirname | sort -u); do
        inside "$d" "$DATA_TOP" && [[ $(readlink -m "$d") != "$(readlink -m "$DATA_TOP")" && -d $d ]] || continue
        find "$d" -maxdepth 1 -name '.backup-*' -type d -exec rm -rf {} + 2>/dev/null || true
        if rmdir "$d" 2>/dev/null; then log_info "Removed empty ${d}"; else log_warn "${d} is not empty - check it and remove it yourself"; fi
    done
}
if ! inside "$CERT" "$DATA_TOP" && ! inside "$KEY" "$DATA_TOP"; then
    log_info "SSL files are already outside PGDATA (${CERT}, ${KEY}) - nothing to move"
    if (( REMOVE_OLD )) && [[ -s $MANIFEST ]]; then
        mapfile -t OLD_FILES < "$MANIFEST"
        log_info "Removing the old files recorded by the earlier move:"
        printf '    %s\n' "${OLD_FILES[@]}"
        confirm_or_exit "delete these old SSL files inside ${DATA_TOP}"
        remove_old "${OLD_FILES[@]}"
        rm -f "$MANIFEST"
        log_audit "Old SSL files inside ${DATA_TOP} removed (after the move to ${TO})"
    fi
    exit 0
fi
for f in "$CERT" "$KEY"; do [[ -r $f ]] || die "Cannot read ${f} as $(id -un)"; done
[[ -z $CA || -r $CA ]] || die "Cannot read ${CA} as $(id -un)"

# The new conf.d/ssl.conf must win: refuse when SSL is also set in postgresql.auto.conf, or in
# postgresql.conf AFTER its include_dir 'conf.d' line.
AUTO="$(grep -iE '^[[:space:]]*ssl[a-z_]*[[:space:]]*=' "${DATA_TOP}/postgresql.auto.conf" 2>/dev/null || true)"
[[ -z $AUTO ]] || die "SSL settings are set with ALTER SYSTEM (postgresql.auto.conf) and would override the new conf.d/ssl.conf. Remove them first, e.g.: psql -c \"ALTER SYSTEM RESET ssl_cert_file\" (same for each ssl_* setting), then re-run."
LATE="$(awk '/^[[:space:]]*include_dir[[:space:]]*=?[[:space:]]*.conf\.d./{inc=1; next} inc && /^[[:space:]]*ssl[a-z_]*[[:space:]]*=/{print FILENAME": "$0}' "${DATA_TOP}/postgresql.conf")"
[[ -z $LATE ]] || die "postgresql.conf sets SSL after its include_dir 'conf.d' line, which would override conf.d/ssl.conf: ${LATE}. Comment those lines out (or move them above include_dir), then re-run."

# --- Collect: passphrase, key, bundle (all in a private temp dir) ---
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if openssl pkey -in "$KEY" -noout -passin pass:_DUMMY_INVALID_ 2>/dev/null; then
    log_warn "The current key is NOT encrypted - it is encrypted now with a new random passphrase (stored in ${TO}/.ssl_key_passphrase, mode 0400). Keep a copy in your vault."
    openssl rand -base64 32 | tr -d '\n' > "${WORK}/pass"
    openssl pkey -in "$KEY" -aes256 -passout file:"${WORK}/pass" -out "${WORK}/key.pem"
else
    [[ -n $PCMD ]] || die "The key is encrypted but ssl_passphrase_command is not set - run epas-ssl-setup.sh --security-top ${TO} with a bundle instead"
    # Run it like the server does: %p = prompt text, %% = %
    CMD="${PCMD//%p/Enter PEM pass phrase:}"; CMD="${CMD//%%/%}"
    timeout 30 sh -c "$CMD" </dev/null 2>/dev/null | head -n1 | tr -d '\n' > "${WORK}/pass" || true
    openssl pkey -in "$KEY" -noout -passin file:"${WORK}/pass" 2>/dev/null \
        || die "ssl_passphrase_command ('${PCMD}') did not give a passphrase that opens ${KEY}. Nothing was changed."
    cp "$KEY" "${WORK}/key.pem"
fi
{
    cat "$CERT"
    if [[ -n $CA ]]; then cat "$CA"
    else   # no CA file: repeat the last certificate of the chain, so the setup keeps the whole chain
        awk '/-BEGIN CERTIFICATE-/{buf=""; keep=1} keep{buf=buf $0 ORS} /-END CERTIFICATE-/{keep=0} END{printf "%s", buf}' "$CERT"
    fi
    cat "${WORK}/key.pem"
} > "${WORK}/bundle.pem"

OLD_FILES=()
for f in "$CERT" "$KEY" ${CA:+"$CA"}; do inside "$f" "$DATA_TOP" && OLD_FILES+=("$f"); done
if [[ -n $PCMD ]]; then
    for w in $PCMD; do [[ $w == /* && -f $w ]] && inside "$w" "$DATA_TOP" && OLD_FILES+=("$w"); done
    PF="$(dirname "$KEY")/.ssl_key_passphrase"; [[ -f $PF ]] && inside "$PF" "$DATA_TOP" && OLD_FILES+=("$PF")
fi
mapfile -t OLD_FILES < <(printf '%s\n' "${OLD_FILES[@]}" | awk '!seen[$0]++')

show_config DATA_TOP TO CERT KEY CA PCMD
confirm_or_exit "move SSL of ${DATA_TOP} to ${TO} (same certificate; installed with epas-ssl-setup.sh, pg_hba.conf untouched; applied with a reload; old files $( ((REMOVE_OLD)) && echo 'deleted' || echo 'kept') after verification)"

# --- Install with the setup script (checks, backup, reload, rollback) ---
SETUP_ENV=(); [[ -n ${ENV_SOURCE:-} ]] && SETUP_ENV=(--env "$ENV_SOURCE")
bash "${SCRIPT_DIR}/epas-ssl-setup.sh" "${SETUP_ENV[@]+"${SETUP_ENV[@]}"}" --yes --names-warn --no-hba \
    --security-top "$TO" --passphrase-file "${WORK}/pass" -b "${WORK}/bundle.pem" \
    || die "epas-ssl-setup.sh did not complete - see above. The old files in PGDATA are untouched."

NEW_KEY="$(epas_conf_get "$DATA_TOP" ssl_key_file)"
[[ $NEW_KEY == "${TO}/server.key" ]] || die "Unexpected: ssl_key_file is now '${NEW_KEY}', not ${TO}/server.key - old files kept"

# --- Old files inside PGDATA ---
if (( ${#OLD_FILES[@]} == 0 )); then
    log_info "No old SSL files inside PGDATA to clean up"
elif (( REMOVE_OLD )); then
    remove_old "${OLD_FILES[@]}"
    log_audit "SSL of ${DATA_TOP} moved to ${TO}; old files inside PGDATA removed"
else
    printf '%s\n' "${OLD_FILES[@]}" > "$MANIFEST"
    log_info "SSL now served from ${TO}. The old files are still inside PGDATA (copied by pg_basebackup and backups until removed):"
    printf '    %s\n' "${OLD_FILES[@]}"
    log_info "Remove them once you are satisfied:  $0 --remove-old"
    log_audit "SSL of ${DATA_TOP} moved to ${TO}; old files kept inside PGDATA (listed in ${MANIFEST})"
fi
log_info "Next: set SECURITY_TOP=${TO} in ${ENV_SOURCE:-conf/site.env} (root), and, for production, re-issue this certificate - old backups contain its key."
