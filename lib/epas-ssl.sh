# shellcheck shell=bash
# =============================================================================
# lib/epas-ssl.sh - read-only checks of an SSL server certificate, shared by
# modules/02-ssl (setup + check-cert.sh), the standby rebuild and the major upgrade.
#
#   epas_ssl_self_names        this host's names and IPs, one per line:
#                              SSL_HOST_NAME if set (only that), else hostname -f, hostname -s, hostname -I
#   epas_ssl_san CERT          the certificate's SAN entries, one per line ("DNS:x", "IP Address:y")
#   epas_ssl_matches CERT NAME 0 if CERT is valid for NAME (DNS name or IP), as a verify-full client
#                              would decide (openssl -checkhost/-checkip: wildcards, CN fallback without SAN)
#   epas_ssl_check_names CERT  prints "OK    ...", "WARN  ..." or "ERROR ..." lines; returns 1 on any ERROR
#       ERROR  the certificate covers none of this host's names/IPs
#       ERROR  it misses a name listed in SSL_SHARED_NAMES (VIP / DNS alias clients use)
#       WARN   it is also valid for another node (PRIMARY_HOST, STANDBY_HOST, PRIMARY_FQDN, STANDBY_FQDN):
#              a shared certificate - one private key on several servers
#       WARN   wildcard name; no SAN at all
#   epas_ssl_days_left CERT    whole days until the certificate expires (negative = expired)
#
# Settings read from the environment / conf/site.env: SSL_HOST_NAME, SSL_SHARED_NAMES,
# PRIMARY_HOST, STANDBY_HOST, PRIMARY_FQDN, STANDBY_FQDN. EPAS_SSL_SELF_NAMES (space-separated)
# replaces host detection - for tests.
# Needs openssl 1.1.1+. Safe to source: changes no shell options, never exits the caller.
# =============================================================================

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo "lib/epas-ssl.sh is a library: source it" >&2
    exit 2
fi

_epas_ssl_is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $1 == *:*:* ]]; }

epas_ssl_self_names() {
    if [[ -n ${EPAS_SSL_SELF_NAMES:-} ]]; then
        tr ' ' '\n' <<< "$EPAS_SSL_SELF_NAMES" | grep -v '^$' || true
        return 0
    fi
    if [[ -n ${SSL_HOST_NAME:-} ]]; then echo "$SSL_HOST_NAME"; return 0; fi
    {
        hostname -f 2>/dev/null || true
        hostname -s 2>/dev/null || true
        hostname -I 2>/dev/null | tr ' ' '\n' || true
    } | grep -v '^$' | grep -vxE '127\.0\.0\.1|::1|localhost(\.localdomain)?' | awk '!seen[$0]++' || true
    return 0
}

epas_ssl_san() {
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tail -n +2 \
        | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
    return 0
}

epas_ssl_matches() {
    local out
    if _epas_ssl_is_ip "$2"; then
        out=$(openssl x509 -in "$1" -noout -checkip "$2" 2>/dev/null || true)
    else
        out=$(openssl x509 -in "$1" -noout -checkhost "$2" 2>/dev/null || true)
    fi
    [[ $out == *" does match"* ]]
}

epas_ssl_days_left() {
    local end
    end=$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2-) || true
    [[ -n $end ]] || return 1
    end=$(date -d "$end" +%s 2>/dev/null) || return 1
    echo $(( (end - $(date +%s)) / 86400 ))
}

epas_ssl_check_names() {
    local cert=$1 n o matched="" err=0
    local -a self=() others=()
    mapfile -t self < <(epas_ssl_self_names)
    for n in "${self[@]+"${self[@]}"}"; do
        if epas_ssl_matches "$cert" "$n"; then matched=$n; break; fi
    done
    if [[ -n $matched ]]; then
        echo "OK    valid for this host ($matched)"
    else
        echo "ERROR not valid for this host (tried: ${self[*]:-none}) - clients using sslmode=verify-full would refuse it. If this host's name is different, set SSL_HOST_NAME in conf/site.env"
        err=1
    fi
    # shellcheck disable=SC2086  # space-separated list on purpose
    for n in ${SSL_SHARED_NAMES:-}; do
        if epas_ssl_matches "$cert" "$n"; then
            echo "OK    valid for shared name $n"
        else
            echo "ERROR not valid for shared name $n (SSL_SHARED_NAMES) - clients connecting through it fail when this node is primary"
            err=1
        fi
    done
    # Also valid for another node? Then it is a shared certificate (one private key on several servers).
    # shellcheck disable=SC2086
    for o in ${PRIMARY_HOST:-} ${STANDBY_HOST:-} ${PRIMARY_FQDN:-} ${STANDBY_FQDN:-}; do
        printf '%s\n' "${self[@]+"${self[@]}"}" | grep -qxF -- "$o" && continue
        printf '%s\n' "${others[@]+"${others[@]}"}" | grep -qxF -- "$o" && continue
        if epas_ssl_matches "$cert" "$o"; then others+=("$o"); fi
    done
    if (( ${#others[@]} > 0 )); then
        echo "WARN  also valid for another server (${others[*]}): a shared certificate, one private key on several servers - fine for DEV/lab; for SIT/PAT/PROD use one certificate per server"
    fi
    if epas_ssl_san "$cert" | grep -q '^DNS:\*'; then
        echo "WARN  wildcard name in the certificate: any server matching it can pose as this database"
    fi
    if [[ -z $(epas_ssl_san "$cert") ]]; then
        echo "WARN  no subjectAltName: clients fall back to the CN; put every name in the SAN"
    fi
    return $err
}
