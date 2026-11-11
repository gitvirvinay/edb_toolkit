#!/usr/bin/env bash
# =============================================================================
# check-cert.sh - read-only report on this server's SSL certificate: names, expiry, fit.
#
#   check-cert.sh [--env conf/site.env] [--days N] [CERT]
#     CERT    default: SECURITY_TOP/server_chained.crt (SECURITY_TOP default /etc/edb/ssl)
#     --days  warn when the certificate expires within N days (default 30)
#
# Checks: the certificate is valid for THIS server and for every name in SSL_SHARED_NAMES
# (VIP / DNS alias); warns when it is shared with another node or is a wildcard; expiry.
# Any user can run it (certificates are world-readable); changes nothing. Cron / monitoring:
# Exit codes: 0 ok | 1 act now (missing, expired, wrong names) | 2 expires within --days
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
# shellcheck source=../../lib/epas-ssl.sh
source "${SCRIPT_DIR}/../../lib/epas-ssl.sh"

WARN_DAYS=30
CERT=""
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)    [[ ${2:-} =~ ^[0-9]+$ ]] || die "--days needs a number"; WARN_DAYS=$2; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        die "Unknown option: $1 (see --help)" ;;
        *)         [[ -z $CERT ]] || die "Only one certificate at a time"; CERT=$1; shift ;;
    esac
done
load_env optional 2>/dev/null
CERT="${CERT:-${SECURITY_TOP:-/etc/edb/ssl}/server_chained.crt}"

[[ -f $CERT ]] || { echo "ERROR certificate not found: $CERT"; exit 1; }
[[ -r $CERT ]] || { echo "ERROR cannot read $CERT as $(id -un)"; exit 1; }
openssl x509 -in "$CERT" -noout >/dev/null 2>&1 || { echo "ERROR not a PEM certificate: $CERT"; exit 1; }

rc=0
echo "Certificate : $CERT"
echo "Subject     : $(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
echo "Issuer      : $(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null | sed 's/^issuer= *//')"
echo "Names (SAN) : $(epas_ssl_san "$CERT" | paste -sd' ' -)"
echo "Expires     : $(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2-)"
DAYS=$(epas_ssl_days_left "$CERT" || echo "")
if [[ -z $DAYS ]]; then
    echo "WARN  could not work out the expiry date"
elif (( DAYS < 0 )); then
    echo "ERROR expired $(( -DAYS )) day(s) ago - clients refuse it; EPAS may not start with it"; rc=1
elif (( DAYS <= WARN_DAYS )); then
    echo "WARN  expires in ${DAYS} day(s) - renew it now (then: epas-ssl-setup.sh -b <new bundle>)"; rc=2
else
    echo "OK    ${DAYS} day(s) left"
fi
NAME_RC=0
epas_ssl_check_names "$CERT" || NAME_RC=$?
(( NAME_RC == 0 )) || rc=1
exit $rc
