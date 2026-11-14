#!/usr/bin/env bash
# =============================================================================
# tests/efm-reconfigure-unit.sh - unit tests for modules/05-efm/efm-reconfigure-after-upgrade.sh
# (the DBA prepares the EFM properties file; the sysadmin installs it).
# No database, no root, no EFM. Run:  tests/efm-reconfigure-unit.sh   or  make test.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: [%s]\n        got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "...$2..." "$3"; fi; }
hasnt(){ if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1" "no $2" "$3"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin17/bin" "$T/data17" "$T/logs" "$T/etc"
printf '#!/bin/sh\nexit 0\n' > "$T/bin17/bin/pg_ctl"; chmod +x "$T/bin17/bin/pg_ctl"
echo 17 > "$T/data17/PG_VERSION"
cat > "$T/site.env" <<EOF
EPAS_VERSION=17
EFM_VERSION=5.3
SYSTEM_USER=$(id -un)
PRIMARY_PORT=5444
SERVICE_NAME=edb-as-17
SRC_BINARY_DIR=$T/bin17
DATA_TOP=$T/data17
TOOLKIT_LOG_DIR=$T/logs
EOF
PROPS="$T/etc/efm.properties"
reset_props() {
    cat > "$PROPS" <<'EOF'
# EFM settings
db.user=efm
db.password.encrypted=SECRETHASH
db.port=5444
db.bin=/usr/edb/as15/bin
db.data.dir=/pgdata/15/data
db.service.name=edb-as-15
db.config.dir=/pgdata/15/data
is.witness=false
EOF
    chmod 640 "$PROPS"
}
run() { env -u TOOLKIT_LOG_FILE bash "$ROOT/modules/05-efm/efm-reconfigure-after-upgrade.sh" --env "$T/site.env" --properties "$PROPS" "$@" </dev/null 2>&1; }
OUTF="$T/logs/efm/efm.properties.epas17"

echo "== builds a corrected copy and leaves the real file alone"
reset_props; before="$(cat "$PROPS")"
out=$(run); rc=$?
eq  "exit code 0"                                   "0" "$rc"
eq  "the real properties file is NOT changed"       "$before" "$(cat "$PROPS")"
has "new db.bin in the copy"                        "db.bin=$T/bin17/bin" "$(cat "$OUTF")"
has "new db.data.dir in the copy"                   "db.data.dir=$T/data17" "$(cat "$OUTF")"
has "new service name in the copy"                  "db.service.name=edb-as-17" "$(cat "$OUTF")"
has "db.config.dir followed the data dir"           "db.config.dir=$T/data17" "$(cat "$OUTF")"
has "the secret is kept in the copy"                "db.password.encrypted=SECRETHASH" "$(cat "$OUTF")"
eq  "the copy is mode 600 (it holds a password)"    "600" "$(stat -c '%a' "$OUTF" 2>/dev/null || stat -f '%Lp' "$OUTF")"
has "shows the differences"                         "db.data.dir=/pgdata/15/data" "$out"
has "tells the sysadmin the backup command"         "cp -a $PROPS $PROPS.bak." "$out"
has "tells the sysadmin the install command"        "install -o $(stat -c %U "$PROPS" 2>/dev/null || stat -f %Su "$PROPS")" "$out"
has "... with the new file as the source"           "$OUTF $PROPS" "$out"
hasnt "the secret is never printed"                 "SECRETHASH" "$out"

echo "== after the sysadmin installed it: 'already up to date'"
cp "$OUTF" "$PROPS"
out=$(run); rc=$?
eq  "exit code 0"                                   "0" "$rc"
has "says nothing to do"                            "already up to date" "$out"
eq  "no leftover copy"                              "no" "$([ -e "$OUTF" ] && echo yes || echo no)"

echo "== witness: only db.port"
reset_props; echo "is.witness=true" >> "$PROPS"; sed -i.bak 's/^db.port=.*/db.port=5555/' "$PROPS"; rm -f "$PROPS.bak"
out=$(run); rc=$?
eq  "exit code 0"                                   "0" "$rc"
has "db.port corrected"                             "db.port=5444" "$(cat "$OUTF")"
has "db.bin untouched"                              "db.bin=/usr/edb/as15/bin" "$(cat "$OUTF")"
rm -f "$OUTF"

echo "== separate config dir is left alone, with a warning"
reset_props; sed -i.bak 's#^db.config.dir=.*#db.config.dir=/etc/edb/conf#' "$PROPS"; rm -f "$PROPS.bak"
out=$(run); has "warns" "is separate from the data dir" "$out"
has "keeps db.config.dir"                           "db.config.dir=/etc/edb/conf" "$(cat "$OUTF")"
rm -f "$OUTF"

echo "== refusals"
out=$(run --properties "$T/etc/missing.properties"); rc=$?
eq  "missing file: exit code 1"                     "1" "$rc"
has "missing file: says so"                         "not found" "$out"
reset_props; chmod 000 "$PROPS"
if [ -r "$PROPS" ]; then ok "(running as root: unreadable-file test skipped)"; else
    out=$(run); rc=$?
    eq  "unreadable file: exit code 1"                  "1" "$rc"
    has "unreadable file: tells what to ask for"        "not readable" "$out"
fi
chmod 640 "$PROPS"
out=$(run --bogus); rc=$?
eq  "unknown option: exit code 1"                   "1" "$rc"
if [ "$(id -u)" -ne 0 ]; then
    grep -q 'require_root' modules/05-efm/efm-reconfigure-after-upgrade.sh; eq "the script no longer asks for root" 1 $?
fi

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
