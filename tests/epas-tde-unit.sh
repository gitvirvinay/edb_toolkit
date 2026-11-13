#!/usr/bin/env bash
# =============================================================================
# tests/epas-tde-unit.sh - unit tests for lib/epas-tde.sh
#
# No database, no root: small files in a temp folder. Run:  bash tests/epas-tde-unit.sh   or  make test
# Exit code 0 = all passed.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
LIB="$PWD/lib/epas-tde.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: [%s]\n        got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "contains: $2" "$3"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== Loading the library"
out=$(bash -euo pipefail -c "source '$LIB'; echo loaded" 2>&1)
eq "loads under set -euo pipefail" "loaded" "$out"
out=$(bash "$LIB" 2>&1); rc=$?
eq "running it directly is refused" "2" "$rc"
# shellcheck source=../lib/epas-tde.sh
source "$LIB"

echo "== epas_tde_passfile"
eq "plain"          "/etc/edb/tde/a.pass" "$(epas_tde_passfile 'openssl enc -d -aes-128-cbc -pbkdf2 -pass file:/etc/edb/tde/a.pass -in %p')"
eq "double quotes"  "/etc/edb/tde/a.pass" "$(epas_tde_passfile 'openssl enc -d -pass "file:/etc/edb/tde/a.pass" -in %p')"
eq "single quotes"  "/etc/edb/tde/a.pass" "$(epas_tde_passfile "openssl enc -d -pass 'file:/etc/edb/tde/a.pass' -in %p")"
eq "no file"        ""                    "$(epas_tde_passfile 'curl https://thales/unwrap')"
eq "env passphrase" ""                    "$(epas_tde_passfile 'openssl enc -d -pass env:TDE_PW -in %p')"

echo "== epas_tde_check_unwrap"
DATA="$TMP/data"; mkdir -p "$DATA" "$TMP/etc"
printf 'secret1' > "$TMP/etc/a.pass"; chmod 600 "$TMP/etc/a.pass"
GOOD="openssl enc -d -aes-128-cbc -pbkdf2 -pass file:$TMP/etc/a.pass -in %p"

out=$(epas_tde_check_unwrap "$GOOD" "$DATA"); rc=$?
eq  "good command: rc 0" "0" "$rc"
has "good command: OK line" "OK    passphrase file" "$out"
has "never prints the passphrase" "OK" "$out"
[[ $out != *secret1* ]] && ok "passphrase not in the output" || bad "passphrase not in the output" "no secret" "$out"

out=$(epas_tde_check_unwrap "" "$DATA"); rc=$?
eq  "empty command: rc 1" "1" "$rc"
has "empty command: ERROR" "ERROR no TDE unwrap command" "$out"

out=$(epas_tde_check_unwrap "openssl enc -d -pass pass:hunter2 -in %p" "$DATA"); rc=$?
eq  "plaintext passphrase: rc 1" "1" "$rc"
has "plaintext passphrase: ERROR" "contains the passphrase itself" "$out"
[[ $out != *hunter2* ]] && ok "plaintext passphrase is not echoed" || bad "plaintext passphrase is not echoed" "no hunter2" "$out"

out=$(epas_tde_check_unwrap "openssl enc -d -pass file:$TMP/etc/missing.pass -in %p" "$DATA"); rc=$?
eq  "missing file: rc 1" "1" "$rc"
has "missing file: ERROR" "does not exist" "$out"

mkdir -p "$DATA/pg_encryption"; printf 'x' > "$DATA/inside.pass"
out=$(epas_tde_check_unwrap "openssl enc -d -pass file:$DATA/inside.pass -in %p" "$DATA"); rc=$?
eq  "file inside the data directory: rc 1" "1" "$rc"
has "file inside the data directory: ERROR" "is inside the data directory" "$out"

printf 'x' > "$TMP/etc/open.pass"; chmod 644 "$TMP/etc/open.pass"
out=$(epas_tde_check_unwrap "openssl enc -d -pass file:$TMP/etc/open.pass -in %p" "$DATA"); rc=$?
eq  "world-readable file: still rc 0" "0" "$rc"
has "world-readable file: WARN" "WARN  passphrase file" "$out"

out=$(epas_tde_check_unwrap "curl -s https://thales.example/unwrap" "$DATA"); rc=$?
eq  "command without a file (Thales): rc 0" "0" "$rc"
has "command without a file: WARN, not checked" "does not use a passphrase file" "$out"

echo "== epas_tde_same_passphrase"
printf 'secret1' > "$TMP/etc/b.pass"; printf 'other' > "$TMP/etc/c.pass"
epas_tde_same_passphrase "$TMP/etc/a.pass" "$TMP/etc/b.pass"; eq "same content" "0" "$?"
epas_tde_same_passphrase "$TMP/etc/a.pass" "$TMP/etc/c.pass"; eq "different content" "1" "$?"
epas_tde_same_passphrase "$TMP/etc/a.pass" "$TMP/etc/none.pass"; eq "cannot compare" "2" "$?"

echo
echo "passed: $PASS   failed: $FAIL"
[[ $FAIL -eq 0 ]]
