#!/usr/bin/env bash
# =============================================================================
# epas-migrate-ssl-conf.sh - carry the OLD cluster's SSL settings to the NEW cluster (major upgrade)
#
#   epas-migrate-ssl-conf.sh [--env conf/site.env] [--old DIR] [--new DIR] [--check] [--yes]
#     --old    old data directory  (default OLD_DATA_TOP)
#     --new    new data directory  (default DATA_TOP)
#     --check  report what would be carried, change nothing (exit 1 if it cannot be carried)
#
# Run as SYSTEM_USER, never as root. epas-major-pgupgrade.sh runs it for you (--check before the
# upgrade, then for real after pg_upgrade, before the new cluster starts). Nothing is restarted.
#
# Reads the old cluster's EFFECTIVE ssl* settings, the way the server does (postgresql.conf with its
# include files and conf.d, then postgresql.auto.conf), and writes them to NEW/conf.d/ssl.conf.
# Refuses - changing nothing - when an SSL file of the old cluster is inside its data directory or a
# relative path (e.g. the default 'server.crt'): the new cluster could not use it, and deleting the old
# cluster would break SSL. Move the files out first: SECURITY_TOP=/etc/edb/ssl + epas-ssl-setup.sh.
# Leaves the new cluster alone when its SSL is already on. An existing NEW/conf.d/ssl.conf is kept
# as ssl.conf.bak_<timestamp>.
# Exit codes: 0 done / nothing to do | 1 cannot be carried, or error
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/epas-detect.sh
source "${SCRIPT_DIR}/../../lib/epas-detect.sh"

OLD_ARG="" NEW_ARG="" CHECK_ONLY=0
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --old)     [[ -n ${2:-} ]] || die "--old needs a directory"; OLD_ARG=$2; shift 2 ;;
        --new)     [[ -n ${2:-} ]] || die "--new needs a directory"; NEW_ARG=$2; shift 2 ;;
        --check)   CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "Unknown option: $1 (see --help)" ;;
    esac
done
load_env optional

OLD="${OLD_ARG:-${OLD_DATA_TOP:-}}"; OLD="${OLD%/}"
NEW="${NEW_ARG:-${DATA_TOP:-}}";     NEW="${NEW%/}"
[[ -n $OLD && -n $NEW ]] || die "Old and new data directories needed: --old/--new, or OLD_DATA_TOP/DATA_TOP in the config"
[ "$(id -u)" -ne 0 ] || die "Run as the database OS user, not root:  sudo -iu ${SYSTEM_USER} $0 ..."
[[ -f $OLD/PG_VERSION ]] || die "Old cluster not found: $OLD (no PG_VERSION)"
[[ -r $OLD/postgresql.conf ]] || die "Cannot read $OLD/postgresql.conf as $(id -un) - run as the cluster owner"
[[ -f $NEW/PG_VERSION ]] || die "New cluster not found: $NEW (no PG_VERSION)"
[[ -O $NEW ]] || die "$NEW is owned by $(stat -c %U "$NEW"), not $(id -un)"

is_on() { [[ ${1,,} =~ ^(on|true|yes|1)$ ]]; }
inside() { case "$(readlink -m "$1")/" in "$(readlink -m "$2")"/*) return 0 ;; esac; return 1; }

OLD_SSL="$(epas_conf_get "$OLD" ssl)"
NEW_SSL="$(epas_conf_get "$NEW" ssl)"
if ! is_on "$OLD_SSL"; then
    log_info "Old cluster ${OLD}: SSL is off - nothing to carry"
    exit 0
fi
if is_on "$NEW_SSL"; then
    log_info "New cluster ${NEW}: SSL is already on (ssl_cert_file = $(epas_conf_get "$NEW" ssl_cert_file)) - kept as is"
    exit 0
fi

# --- Every SSL file must be usable by the new cluster and outlive the old one ---
PROBLEMS=()
for p in ssl_cert_file ssl_key_file ssl_ca_file ssl_crl_file ssl_crl_dir ssl_dh_params_file; do
    v="$(epas_conf_get "$OLD" "$p")"
    case $p in                        # server defaults, relative to the data directory
        ssl_cert_file) v=${v:-server.crt} ;;
        ssl_key_file)  v=${v:-server.key} ;;
    esac
    [[ -n $v ]] || continue
    if [[ $v != /* ]]; then
        PROBLEMS+=("$p = '$v' is relative to the old data directory")
    elif inside "$v" "$OLD"; then
        PROBLEMS+=("$p = '$v' is inside the old data directory")
    elif [[ ! -e $v ]]; then
        PROBLEMS+=("$p = '$v' does not exist on this host")
    fi
done
CMD="$(epas_conf_get "$OLD" ssl_passphrase_command)"
if [[ -n $CMD && $CMD == *"$OLD"* ]]; then
    PROBLEMS+=("ssl_passphrase_command = '$CMD' uses a file inside the old data directory")
fi
if (( ${#PROBLEMS[@]} > 0 )); then
    for p in "${PROBLEMS[@]}"; do log_error "$p"; done
    die "The old cluster's SSL settings cannot be carried to ${NEW}. Nothing was changed. Move the SSL files out of the old data directory first: SECURITY_TOP=/etc/edb/ssl, then run epas-ssl-setup.sh against the OLD cluster (a config whose DATA_TOP is ${OLD}); then run this again."
fi

# --- New conf.d/ssl.conf: the effective old values, as the old server used them ---
OUT="${NEW}/conf.d/ssl.conf"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
{
    echo "# Carried from ${OLD} by edb_toolkit epas-migrate-ssl-conf.sh on $(date '+%F %T')"
    echo "# (re-running epas-ssl-setup.sh on this cluster replaces this file)"
    for p in ssl ssl_cert_file ssl_key_file ssl_ca_file ssl_crl_file ssl_crl_dir ssl_dh_params_file \
             ssl_passphrase_command ssl_passphrase_command_supports_reload ssl_min_protocol_version \
             ssl_max_protocol_version ssl_ciphers ssl_prefer_server_ciphers ssl_ecdh_curve; do
        v="$(epas_conf_get "$OLD" "$p")"
        [[ -n $v ]] || continue
        printf "%s = '%s'\n" "$p" "${v//\'/\'\'}"
    done
} > "${WORK}/ssl.conf"

if (( CHECK_ONLY )); then
    log_info "Check only: SSL settings of ${OLD} can be carried to ${OUT}:"
    sed 's/^/    /' "${WORK}/ssl.conf"
    exit 0
fi

show_config OLD NEW OUT
confirm_or_exit "write the old cluster's SSL settings to ${OUT} (an existing one is kept as .bak_<timestamp>); nothing is restarted"

[[ ! -L ${NEW}/conf.d && ! -L $OUT && ! -L ${NEW}/postgresql.conf ]] || die "Refusing to write through a symbolic link in ${NEW}"
mkdir -p "${NEW}/conf.d"
if [[ -f $OUT ]]; then
    cp -p "$OUT" "${OUT}.bak_$(date +%F_%H%M%S)"
    log_info "Existing ${OUT} kept as ${OUT}.bak_*"
fi
TMP="$(mktemp "${NEW}/conf.d/.ssl.conf.XXXXXX")"
cat "${WORK}/ssl.conf" > "$TMP"; chmod 0600 "$TMP"; mv -f "$TMP" "$OUT"

PG_CONF="${NEW}/postgresql.conf"
if ! grep -qE "^include_dir\s*=\s*['\"]conf.d['\"]" "$PG_CONF" 2>/dev/null; then
    TMP="$(mktemp "${NEW}/.postgresql.conf.XXXXXX")"
    cat "$PG_CONF" > "$TMP"; echo "include_dir = 'conf.d'" >> "$TMP"; chmod 0600 "$TMP"; mv -f "$TMP" "$PG_CONF"
    log_info "Added include_dir = 'conf.d' to ${PG_CONF}"
fi

log_info "Wrote ${OUT}:"
sed 's/^/    /' "$OUT"
log_audit "SSL settings carried from ${OLD} to ${OUT}"
