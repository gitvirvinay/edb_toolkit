#!/usr/bin/env bash
# =============================================================================
# tests/epas-ssl-unit.sh - unit tests for lib/epas-ssl.sh (certificate name checks)
#
# No database, no root: test certificates are made with openssl in a temp folder.
# Run:  tests/epas-ssl-unit.sh   or  make test.   Exit code 0 = all passed.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
LIB="$PWD/lib/epas-ssl.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: [%s]\n        got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "...$2..." "$3"; fi; }      # has NAME NEEDLE HAYSTACK
hasnt(){ if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1" "no $2" "$3"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkcert() {   # mkcert NAME CN [SAN] [DAYS]
    local ext=()
    [[ -n ${3:-} ]] && ext=(-addext "subjectAltName=$3")
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/$1.key" -out "$TMP/$1.crt" \
        -days "${4:-30}" -subj "/CN=$2" "${ext[@]}" >/dev/null 2>&1
}

echo "== Loading the library"
out=$(bash -euo pipefail -c "source '$LIB'; echo loaded" 2>&1)
eq "loads under set -euo pipefail"       "loaded" "$out"
out=$(bash -c "o1=\$(set +o); source '$LIB'; o2=\$(set +o); [[ \$o1 == \"\$o2\" ]] && echo same" 2>&1)
eq "changes no shell options"            "same" "$out"
out=$(bash "$LIB" 2>&1); rc=$?
eq "running it directly is refused"      "2" "$rc"
# shellcheck source=../lib/epas-ssl.sh
source "$LIB"

mkcert own      db01.example.com "DNS:db01.example.com,IP:10.0.0.11,DNS:pgprod.example.com"
mkcert shared   db01.example.com "DNS:db01.example.com,DNS:db02.example.com,IP:10.0.0.11,IP:10.0.0.12"
mkcert wild     db01.example.com "DNS:*.example.com"
mkcert nosan    db01.example.com ""
mkcert otherdb  db03.example.com "DNS:db03.example.com,IP:10.0.0.13"

echo "== SAN and matching"
eq "san lists every entry"   "DNS:db01.example.com IP Address:10.0.0.11 DNS:pgprod.example.com" "$(epas_ssl_san "$TMP/own.crt" | paste -sd' ' -)"
yes_() { if "${@:2}"; then ok "$1"; else bad "$1" true false; fi; }
no_()  { if "${@:2}"; then bad "$1" false true; else ok "$1"; fi; }
yes_ "matches its DNS name"           epas_ssl_matches "$TMP/own.crt" db01.example.com
yes_ "matches its IP"                 epas_ssl_matches "$TMP/own.crt" 10.0.0.11
no_  "does not match another name"    epas_ssl_matches "$TMP/own.crt" db02.example.com
no_  "does not match another IP"     epas_ssl_matches "$TMP/own.crt" 10.0.0.12
no_  "short name is not the FQDN"     epas_ssl_matches "$TMP/own.crt" db01
yes_ "wildcard matches one level"     epas_ssl_matches "$TMP/wild.crt" db07.example.com
no_  "wildcard not two levels"        epas_ssl_matches "$TMP/wild.crt" a.b.example.com
yes_ "no SAN: CN fallback"            epas_ssl_matches "$TMP/nosan.crt" db01.example.com
d=$(epas_ssl_days_left "$TMP/own.crt")
yes_ "days left is 29 or 30 ($d)"     test "$d" -ge 29 -a "$d" -le 30

echo "== Name check (epas_ssl_check_names)"
export EPAS_SSL_SELF_NAMES="db01.example.com db01 10.0.0.11"
unset SSL_SHARED_NAMES PRIMARY_HOST STANDBY_HOST PRIMARY_FQDN STANDBY_FQDN SSL_HOST_NAME
out=$(epas_ssl_check_names "$TMP/own.crt"); rc=$?
eq  "own cert: passes"                   "0" "$rc"
has "own cert: says which name matched"  "OK    valid for this host (db01.example.com)" "$out"
hasnt "own cert: no warning"             "WARN" "$out"

out=$(SSL_SHARED_NAMES="pgprod.example.com" epas_ssl_check_names "$TMP/own.crt"); rc=$?
eq  "shared name present: passes"        "0" "$rc"
has "shared name present: reported"      "OK    valid for shared name pgprod.example.com" "$out"
out=$(SSL_SHARED_NAMES="pgprod.example.com pgvip.example.com" epas_ssl_check_names "$TMP/own.crt"); rc=$?
eq  "shared name missing: fails"         "1" "$rc"
has "shared name missing: named"         "ERROR not valid for shared name pgvip.example.com" "$out"

out=$(epas_ssl_check_names "$TMP/otherdb.crt"); rc=$?
eq  "another server's cert: fails"       "1" "$rc"
has "another server's cert: explains"    "ERROR not valid for this host" "$out"

out=$(EPAS_SSL_SELF_NAMES="10.0.0.11" epas_ssl_check_names "$TMP/own.crt"); rc=$?
eq  "matched by IP only: passes"         "0" "$rc"

out=$(PRIMARY_HOST=10.0.0.11 STANDBY_HOST=10.0.0.12 STANDBY_FQDN=db02.example.com epas_ssl_check_names "$TMP/shared.crt"); rc=$?
eq  "shared cert: still passes"          "0" "$rc"
has "shared cert: warns, names the other" "WARN  also valid for another server (10.0.0.12 db02.example.com)" "$out"
out=$(PRIMARY_HOST=10.0.0.11 STANDBY_HOST=10.0.0.12 epas_ssl_check_names "$TMP/own.crt")
hasnt "own cert: this host is not 'another server'" "WARN" "$out"

out=$(epas_ssl_check_names "$TMP/wild.crt"); rc=$?
eq  "wildcard: passes"                   "0" "$rc"
has "wildcard: warns"                    "WARN  wildcard" "$out"
out=$(epas_ssl_check_names "$TMP/nosan.crt"); rc=$?
eq  "no SAN: passes via CN"              "0" "$rc"
has "no SAN: warns"                      "WARN  no subjectAltName" "$out"

out=$(unset EPAS_SSL_SELF_NAMES; SSL_HOST_NAME=db01.example.com epas_ssl_self_names)
eq  "SSL_HOST_NAME replaces detection"   "db01.example.com" "$out"

echo
echo "Result: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
