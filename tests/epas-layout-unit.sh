#!/usr/bin/env bash
# =============================================================================
# tests/epas-layout-unit.sh - unit tests for lib/epas-layout.sh (storage layout checks)
#
# No database, no root, no real mounts: the filesystem lookups are replaced by fakes.
# Run:  tests/epas-layout-unit.sh   or  make test.   Exit code 0 = all passed.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
LIB="$PWD/lib/epas-layout.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: [%s]\n        got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "...$2..." "$3"; fi; }
hasnt(){ if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1" "no $2" "$3"; fi; }

echo "== Loading the library"
out=$(bash -euo pipefail -c "source '$LIB'; echo loaded" 2>&1)
eq "loads under set -euo pipefail"   "loaded" "$out"
out=$(bash -c "o1=\$(set +o); source '$LIB'; o2=\$(set +o); [[ \$o1 == \"\$o2\" ]] && echo same" 2>&1)
eq "changes no shell options"        "same" "$out"
out=$(bash "$LIB" 2>&1); rc=$?
eq "running it directly is refused"  "2" "$rc"
# shellcheck source=../lib/epas-layout.sh
source "$LIB"

echo "== Path validation"
epas_layout_valid_path /pgwal/as17;      eq "plain path accepted"        0 $?
epas_layout_valid_path pgwal/as17;       eq "relative path refused"      1 $?
epas_layout_valid_path '/pg wal/as17';   eq "space refused"              1 $?
epas_layout_valid_path '/pgwal/../etc';  eq "'..' refused"               1 $?
epas_layout_valid_path '/pgwal/$(id)';   eq "shell characters refused"   1 $?
epas_layout_valid_path /;                eq "bare / refused"             1 $?

echo "== Parents the toolkit may hand to the DB user"
epas_layout_parent_ok /pgdata/as17;        eq "/pgdata ok"               0 $?
epas_layout_parent_ok /u001/data/as17;     eq "/u001/data ok"            0 $?
epas_layout_parent_ok /var/lib/edb/as17;   eq "/var/lib/edb ok"          0 $?
epas_layout_parent_ok /pglog/toolkit;      eq "toolkit log dir on the log mount ok"  0 $?
epas_layout_parent_ok /var/log/edb-toolkit; eq "toolkit log dir in /var/log refused" 1 $?
epas_layout_parent_ok /as17;               eq "/ refused"                1 $?
epas_layout_parent_ok /var/lib/as17;       eq "/var/lib refused"         1 $?
epas_layout_parent_ok /etc/edb/as17;       eq "/etc/... refused"         1 $?
epas_layout_parent_ok /opt/as17;           eq "/opt refused"             1 $?

echo "== Mount check (fake filesystems)"
# fake: device id and mount point = the first path component ('/' for paths under /root-ish)
epas_layout_fs_id() {
    case "$1" in
        /) echo 1 ;;
        /pgdata*|/pgdata2*) echo 10 ;;
        /pgwal*)     echo 20 ;;
        /pgarchive*) echo "${FAKE_ARCHIVE_ID:-30}" ;;
        /pgbackup*)  echo 40 ;;
        /pglog*)     echo "${FAKE_LOG_ID:-50}" ;;
        *)           echo 1 ;;
    esac
}
epas_layout_fs_target() { local p=${1#/}; echo "/${p%%/*}"; }

DATA_TOP=/pgdata/as17 WAL_TOP=/pgwal/as17 ARCHIVE_TOP=/pgarchive/as17 BACKUP_TOP=/pgbackup/as17 LOG_TOP=/pglog/as17
out=$(epas_layout_check); rc=$?
eq  "full layout: rc 0"                         0 "$rc"
hasnt "full layout: no WARN"                    "WARN" "$out"
has "full layout: WAL reported on its mount"    "OK    WAL_TOP /pgwal/as17 (own filesystem /pgwal)" "$out"

FAKE_LOG_ID=10 out=$(epas_layout_check); rc=$?
eq  "log on data filesystem: rc 1"              1 "$rc"
has "log on data filesystem: warned"            "WARN  LOG_TOP /pglog/as17 shares a filesystem with DATA_TOP" "$out"

FAKE_ARCHIVE_ID=20 out=$(epas_layout_check); rc=$?
eq  "archive on WAL filesystem: rc 1"           1 "$rc"
has "archive on WAL filesystem: warned"         "WARN  ARCHIVE_TOP /pgarchive/as17 shares a filesystem with WAL_TOP" "$out"

WAL_TOP=/srv/wal/as17 out=$(epas_layout_check); rc=$?
eq  "WAL on root filesystem: rc 1"              1 "$rc"
has "WAL on root filesystem: warned"            "WARN  WAL_TOP /srv/wal/as17 is on the root filesystem" "$out"

WAL_TOP="" LOG_TOP="" ARCHIVE_TOP="" BACKUP_TOP="" out=$(epas_layout_check); rc=$?
eq  "old layout: rc 1"                          1 "$rc"
has "old layout: WAL warning"                   "WAL_TOP is empty - pg_wal stays inside PGDATA" "$out"
has "old layout: log warning"                   "LOG_TOP is empty - server logs stay inside PGDATA" "$out"
hasnt "old layout: unset folders not listed"    "ARCHIVE_TOP" "$out"

echo "== Template (conf/site.env.example)"
out=$(bash -c 'set -u; source conf/site.env.example; echo "$DATA_TOP|$WAL_TOP|$ARCHIVE_TOP|$BACKUP_TOP|$LOG_TOP"' 2>&1)
eq "derived per-cluster folders"  "/pgdata/as17|/pgwal/as17|/pgarchive/as17|/pgbackup/as17|/pglog/as17" "$out"
out=$(bash -c 'set -u; sed -e "s|^WAL_MOUNT=.*|WAL_MOUNT=\"\"|" -e "s|^LOG_MOUNT=.*|LOG_MOUNT=\"\"|" conf/site.env.example > /tmp/layout-unit.$$; source /tmp/layout-unit.$$; rm -f /tmp/layout-unit.$$; echo "[$WAL_TOP][$LOG_TOP]"' 2>&1)
eq "empty mount -> empty folder"  "[][]" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
