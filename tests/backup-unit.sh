#!/usr/bin/env bash
# =============================================================================
# tests/backup-unit.sh - unit tests for modules/06-backup/archive-wal.sh,
# enable-wal-archiving.sh and take-basebackup.sh (BACKUP_TOOL=basebackup).
#
# No database, no root: systemctl and pg_basebackup are fakes; files are temp dirs.
# Run:  tests/backup-unit.sh   or  make test.   Exit code 0 = all passed.
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

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/logs" "$T/archive" "$T/data/conf.d" "$T/backup"

# sudo: drop its own options, run the command (none of these scripts call sudo, kept for parity)
cat > "$T/bin/sudo" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -n) shift;; -u) shift 2;; *) break;; esac; done
exec "$@"
FAKE
# systemctl is-active --quiet UNIT: exit 0 if UNIT is in $T/active, else exit 3
cat > "$T/bin/systemctl" <<FAKE
#!/bin/sh
if [ "\$1" = "is-active" ]; then
    shift; [ "\$1" = "--quiet" ] && shift
    grep -qx "\$1" "$T/active" 2>/dev/null && exit 0 || exit 3
fi
echo "systemctl \$*" >> "$T/calls"; exit 0
FAKE
# pg_basebackup -D DEST ...: make DEST and a backup_label, unless $T/basebackup_fail exists
cat > "$T/bin/pg_basebackup" <<FAKE
#!/bin/sh
echo "pg_basebackup \$*" >> "$T/calls"
dest=""
while [ \$# -gt 0 ]; do [ "\$1" = "-D" ] && { dest="\$2"; shift; }; shift; done
[ -f "$T/basebackup_fail" ] && { echo "simulated failure" >&2; exit 1; }
mkdir -p "\$dest"
echo "START WAL LOCATION: 0/0" > "\$dest/backup_label"
exit 0
FAKE
chmod +x "$T"/bin/*

env_file() {
    {
        echo "SYSTEM_USER=$(whoami)"
        echo "BINARY_TOP=$T"
        echo "DATA_TOP=$T/data"
        echo "ARCHIVE_TOP=$T/archive"
        echo "BACKUP_TOP=$T/backup"
        echo "PRIMARY_PORT=5444"
        echo "EPAS_SERVICE=edb-as-test"
        echo "TOOLKIT_LOG_DIR=$T/logs"
        printf '%s\n' "$@"
    } > "$T/site.env"
}
run() {  # run SCRIPT ARGS... - with the fakes first on PATH, not on a terminal
    env -u TOOLKIT_LOG_FILE -u HA_TOOL -u SITE -u BACKUP_TOOL -u APP_CODE -u BACKUP_RETENTION_DAYS \
        PATH="$T/bin:$PATH" bash "$ROOT/$1" --env "$T/site.env" "${@:2}" </dev/null 2>&1
}
calls() { tr '\n' ';' < "$T/calls"; }
reset() { : > "$T/calls"; rm -f "$T/data/conf.d/06-archiving.conf" "$T/active" "$T/basebackup_fail"; rm -rf "$T/backup"/*; }

echo "== archive-wal.sh"
reset
printf 'wal-segment-content' > "$T/srcwal"
out=$(env PATH="$T/bin:$PATH" bash "$ROOT/modules/06-backup/archive-wal.sh" "$T/archive" "$T/srcwal" "000000010000000000000001" 2>&1); rc=$?
eq   "first archive: succeeds"                 "0" "$rc"
eq   "first archive: file lands in ARCHIVE_TOP" "wal-segment-content" "$(cat "$T/archive/000000010000000000000001")"
out=$(env PATH="$T/bin:$PATH" bash "$ROOT/modules/06-backup/archive-wal.sh" "$T/archive" "$T/srcwal" "000000010000000000000001" 2>&1); rc=$?
eq   "re-archive, identical content: succeeds (idempotent)" "0" "$rc"
has  "re-archive, identical content: says so"   "already archived" "$out"
printf 'DIFFERENT content' > "$T/srcwal2"
out=$(env PATH="$T/bin:$PATH" bash "$ROOT/modules/06-backup/archive-wal.sh" "$T/archive" "$T/srcwal2" "000000010000000000000001" 2>&1); rc=$?
eq   "re-archive, different content: refused"   "1" "$rc"
has  "re-archive, different content: says why"  "refusing to overwrite" "$out"
eq   "re-archive, different content: archive not changed" "wal-segment-content" "$(cat "$T/archive/000000010000000000000001")"
out=$(env PATH="$T/bin:$PATH" bash "$ROOT/modules/06-backup/archive-wal.sh" "$T/no-such-dir" "$T/srcwal" "x" 2>&1); rc=$?
eq   "missing archive dir: refused"             "1" "$rc"

echo "== enable-wal-archiving.sh"
reset
env_file 'BACKUP_TOOL="pgbackrest"'
out=$(run modules/06-backup/enable-wal-archiving.sh)
has  "BACKUP_TOOL=pgbackrest: explains and does nothing" "pgBackRest's own job" "$out"
eq   "BACKUP_TOOL=pgbackrest: no conf.d file written"    "0" "$([ -f "$T/data/conf.d/06-archiving.conf" ] && echo 1 || echo 0)"

env_file 'BACKUP_TOOL="none"'
out=$(run modules/06-backup/enable-wal-archiving.sh)
has  "BACKUP_TOOL=none: explains and does nothing"       "nowhere" "$out"

env_file 'BACKUP_TOOL="basebackup"'
out=$(run modules/06-backup/enable-wal-archiving.sh); rc=$?
eq   "BACKUP_TOOL=basebackup, EPAS not running: succeeds" "0" "$rc"
eq   "stages conf.d/06-archiving.conf"                   "1" "$([ -f "$T/data/conf.d/06-archiving.conf" ] && echo 1 || echo 0)"
has  "archive_mode is on"                                "archive_mode = on" "$(cat "$T/data/conf.d/06-archiving.conf")"
has  "archive_command points at archive-wal.sh and ARCHIVE_TOP" "archive-wal.sh $T/archive" "$(cat "$T/data/conf.d/06-archiving.conf")"
has  "not running: says archiving starts clean"          "active from the first start" "$out"

echo "edited by hand" >> "$T/data/conf.d/06-archiving.conf"
out=$(run modules/06-backup/enable-wal-archiving.sh)
has  "run again: keeps the local version"                "keeping local version" "$out"
has  "run again: local edit is untouched"                "edited by hand" "$(cat "$T/data/conf.d/06-archiving.conf")"

echo "edb-as-test" > "$T/active"
out=$(run modules/06-backup/enable-wal-archiving.sh)
has  "EPAS already running: warns a restart is needed"   "only takes effect after a RESTART" "$out"

echo "== take-basebackup.sh"
reset
env_file 'BACKUP_TOOL="pgbackrest"'
out=$(run modules/06-backup/take-basebackup.sh); rc=$?
eq   "BACKUP_TOOL=pgbackrest: refused"                   "1" "$rc"
has  "BACKUP_TOOL=pgbackrest: points elsewhere"          "BACKUP_TOOL=pgbackrest" "$out"

env_file 'BACKUP_TOOL="basebackup"' "SYSTEM_USER=nobody-such-user"
out=$(run modules/06-backup/take-basebackup.sh); rc=$?
eq   "wrong OS user: refused"                            "1" "$rc"
has  "wrong OS user: says which user to use"             "Run this as nobody-such-user" "$out"

env_file 'BACKUP_TOOL="basebackup"'
out=$(run modules/06-backup/take-basebackup.sh); rc=$?
eq   "EPAS not running: refused"                         "1" "$rc"
has  "EPAS not running: says so"                         "is not running" "$out"

echo "edb-as-test" > "$T/active"
out=$(run modules/06-backup/take-basebackup.sh --yes); rc=$?
eq   "EPAS running, first backup: succeeds"              "0" "$rc"
eq   "backup_label was left by pg_basebackup"            "1" "$(find "$T/backup" -name backup_label | wc -l | tr -d ' ')"
eq   "exactly one backup directory now exists"           "1" "$(find "$T/backup" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
has  "audit line written"                                "AUDIT" "$(cat "$T"/logs/*.log 2>/dev/null)"

: > "$T/basebackup_fail"
out=$(run modules/06-backup/take-basebackup.sh --yes old_one); rc=$?
eq   "pg_basebackup fails: script fails too"             "1" "$rc"
eq   "pg_basebackup fails: the earlier backup is untouched" "1" "$(find "$T/backup" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"

echo "== take-basebackup.sh: retention needs confirmation"
reset
env_file 'BACKUP_TOOL="basebackup"'
echo "edb-as-test" > "$T/active"
OLD_DIR="$T/backup/2020-01-01_000000_old"
mkdir -p "$OLD_DIR"; touch -d '30 days ago' "$OLD_DIR" 2>/dev/null || touch -t 202001010000 "$OLD_DIR"
out=$(run modules/06-backup/take-basebackup.sh); rc=$?       # no --yes, not a terminal
eq   "no --yes: a new backup is still taken"             "1" "$([ -d "$T/backup" ] && find "$T/backup" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ' | awk '{print ($1>=2)}')"
eq   "no --yes: pruning is refused"                      "1" "$rc"
has  "no --yes: says why"                                "needs --yes" "$out"
eq   "no --yes: the old backup is NOT deleted"            "1" "$([ -d "$OLD_DIR" ] && echo 1 || echo 0)"
out=$(run modules/06-backup/take-basebackup.sh --yes); rc=$?
eq   "--yes: pruning succeeds"                           "0" "$rc"
eq   "--yes: the old backup IS deleted"                  "0" "$([ -d "$OLD_DIR" ] && echo 1 || echo 0)"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
