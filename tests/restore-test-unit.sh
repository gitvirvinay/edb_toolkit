#!/usr/bin/env bash
# =============================================================================
# tests/restore-test-unit.sh - unit tests for modules/06-backup/restore-test.sh
#
# No database, no root: pg_ctl, pg_isready, psql, pg_verifybackup and df are fakes; the "backups"
# are temp directories. Run:  tests/restore-test-unit.sh   or  make test.   Exit 0 = all passed.
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
mkdir -p "$T/bin" "$T/logs" "$T/archive" "$T/data" "$T/backup"

# pg_verifybackup [--no-parse-wal] DIR: ok, unless $T/verify_fail exists
cat > "$T/bin/pg_verifybackup" <<FAKE
#!/bin/sh
echo "pg_verifybackup \$*" >> "$T/calls"
[ -f "$T/verify_fail" ] && { echo "pg_verifybackup: error: checksum mismatch" >&2; exit 1; }
echo "backup successfully verified"; exit 0
FAKE
# df --output=avail -B1 DIR: a tiny number when $T/df_small exists, the real answer otherwise
cat > "$T/bin/df" <<FAKE
#!/bin/sh
if [ -f "$T/df_small" ]; then printf 'Avail\n  1000\n'; else exec /bin/df "\$@"; fi
FAKE
# The temporary instance is faked with a few flag files in $T:
#   pg_running = the "postmaster" is alive      pg_ready = it accepts connections
# Knobs a test can switch on: start_fail, instance_dies, never_ready, port_busy, still_recovery, write_fail
cat > "$T/bin/pg_ctl" <<FAKE
#!/bin/sh
cmd="\$1"; shift
echo "pg_ctl \$cmd \$*" >> "$T/calls"
case "\$cmd" in
  start)
    dir=""; log=""
    while [ \$# -gt 0 ]; do case "\$1" in -D) dir="\$2"; shift;; -l) log="\$2"; shift;; esac; shift; done
    [ -f "$T/start_fail" ] && exit 1
    { [ -f "\$dir/recovery.signal" ] && echo "recovery.signal"; [ -f "\$dir/backup_label" ] && echo "backup_label"
      echo "mode=\$(stat -c %a "\$dir")"; } > "$T/start_facts"
    if [ -f "$T/instance_dies" ]; then echo 'FATAL:  could not locate required checkpoint record' > "\$log"; exit 0; fi
    : > "$T/pg_running"
    { echo 'LOG:  restored log file "000000010000000000000003" from archive'
      echo 'LOG:  restored log file "000000010000000000000004" from archive'
      echo 'LOG:  restored log file "000000010000000000000005" from archive'
      echo 'LOG:  redo done at 0/5000028'
      echo 'LOG:  last completed transaction was at log time 2026-11-10 03:01:02+00'
      echo 'LOG:  archive recovery complete'; } > "\$log"
    [ -f "$T/never_ready" ] || : > "$T/pg_ready" ;;
  status) [ -f "$T/pg_running" ] ;;
  stop)   rm -f "$T/pg_running" "$T/pg_ready" ;;
esac
FAKE
cat > "$T/bin/pg_isready" <<FAKE
#!/bin/sh
case "\$*" in *localhost*) [ -f "$T/port_busy" ] && exit 0; exit 2;; esac
[ -f "$T/pg_ready" ] && exit 0; exit 2
FAKE
cat > "$T/bin/psql" <<FAKE
#!/bin/sh
case "\$*" in
  *pg_is_in_recovery*) [ -f "$T/still_recovery" ] && echo t || echo f ;;
  *restore_probe*)     [ -f "$T/write_fail" ] && { echo "ERROR: read-only transaction" >&2; exit 1; }; echo 1 ;;
esac
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
run() {  # run ARGS... - the fakes first on PATH, not on a terminal
    env -u TOOLKIT_LOG_FILE -u HA_TOOL -u SITE -u BACKUP_TOOL -u APP_CODE -u RESTORE_TOP -u RESTORE_TEST_PORT \
        -u RESTORE_TEST_TIMEOUT_HOURS -u RESTORE_TEST_KEEP_MAX -u RESTORE_EVIDENCE_DIR \
        PATH="$T/bin:$PATH" bash "$ROOT/modules/06-backup/restore-test.sh" --env "$T/site.env" "$@" </dev/null 2>&1
}
calls() { tr '\n' ';' < "$T/calls"; }
# mkbackup NAME [incomplete] - a pretend pg_basebackup result
mkbackup() {
    mkdir -p "$T/backup/$1/base"
    echo "START WAL LOCATION: 0/0" > "$T/backup/$1/backup_label"
    [ "${2:-}" = "incomplete" ] || echo '{}' > "$T/backup/$1/backup_manifest"
    echo "datafile" > "$T/backup/$1/base/16384"
}
reset() { : > "$T/calls"; rm -rf "$T/backup"/* "$T/logs"/* "$T/archive"/* "$T/tde"; rm -f "$T/verify_fail" "$T/df_small" "$T/pg_running" "$T/pg_ready" "$T/start_fail" "$T/instance_dies" "$T/never_ready" "$T/port_busy" "$T/still_recovery" "$T/write_fail" "$T/start_facts"; env_file 'BACKUP_TOOL="basebackup"'; }
chosen() { sed -n 's/.*Backup chosen.*: //p' <<< "$1" | head -1; }

echo "== restore-test.sh: guards"
reset; mkbackup 2026-11-10_020000_scheduled
env_file 'BACKUP_TOOL="pgbackrest"'
out=$(run --check-only); rc=$?
eq   "BACKUP_TOOL=pgbackrest: refused"                   "1" "$rc"
has  "BACKUP_TOOL=pgbackrest: says why"                  "BACKUP_TOOL=pgbackrest" "$out"
env_file 'BACKUP_TOOL="basebackup"' "SYSTEM_USER=nobody-such-user"
out=$(run --check-only); rc=$?
eq   "wrong OS user: refused"                            "1" "$rc"
has  "wrong OS user: names the right user"               "Run this as nobody-such-user" "$out"
env_file 'BACKUP_TOOL="basebackup"' "RESTORE_TEST_PORT=5444"
out=$(run --check-only); rc=$?
eq   "port of the real database: refused"                "1" "$rc"
has  "port of the real database: says so"                "real database's port" "$out"
env_file 'BACKUP_TOOL="basebackup"' "RESTORE_TEST_TIMEOUT_HOURS=abc"
out=$(run --check-only); rc=$?
eq   "timeout that is not a number: refused"             "1" "$rc"
env_file 'BACKUP_TOOL="basebackup"' "RESTORE_TOP=$T/archive"
out=$(run --check-only); rc=$?
eq   "RESTORE_TOP = a real data folder: refused"         "1" "$rc"
env_file 'BACKUP_TOOL="basebackup"' "RESTORE_TOP='/tmp/with space'"
out=$(run --check-only); rc=$?
eq   "RESTORE_TOP with odd characters: refused"          "1" "$rc"
env_file 'BACKUP_TOOL="basebackup"'
out=$(run --pick=sometimes); rc=$?
eq   "unknown --pick value: refused"                     "1" "$rc"
rm -rf "$T/backup"/*
out=$(run --check-only); rc=$?
eq   "no backups at all: refused"                        "1" "$rc"
has  "no backups at all: says what to do"                "take-basebackup.sh" "$out"

echo "== restore-test.sh: which backup"
reset
mkbackup 2026-11-08_020000_scheduled
mkbackup 2026-11-09_020000_scheduled
mkbackup 2026-11-10_020000_scheduled
mkbackup 2026-11-11_020000_scheduled incomplete        # no backup_manifest: still being written, or failed
mkdir -p "$T/backup/restore-test"                       # our own folder: never a candidate
out=$(run --check-only); rc=$?
eq   "default is latest: succeeds"                       "0" "$rc"
eq   "latest skips the incomplete newest backup"         "2026-11-10_020000_scheduled" "$(chosen "$out")"
ok_random=1
for _ in 1 2 3 4 5 6 7 8; do
    out=$(run --pick random --check-only); c="$(chosen "$out")"
    case "$c" in 2026-11-08_020000_scheduled|2026-11-09_020000_scheduled|2026-11-10_020000_scheduled) ;; *) ok_random=0 ;; esac
done
eq   "random always picks a complete backup"             "1" "$ok_random"

echo "== restore-test.sh: safety checks"
reset; mkbackup 2026-11-10_020000_scheduled
out=$(run --check-only); rc=$?
eq   "good backup: all checks pass"                      "0" "$rc"
has  "check 4 ran pg_verifybackup on the chosen backup"  "pg_verifybackup $T/backup/2026-11-10_020000_scheduled" "$(calls)"
hasnt "no TDE: WAL parsing is not switched off"          "--no-parse-wal" "$(calls)"
has  "--check-only says nothing was restored"            "Nothing was restored" "$out"
eq   "--check-only copied nothing"                       "0" "$(find "$T/backup/restore-test" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

: > "$T/df_small"
out=$(run --check-only); rc=$?
eq   "not enough free space: refused"                    "1" "$rc"
has  "not enough free space: says so"                    "Not enough space" "$out"
rm -f "$T/df_small"

: > "$T/verify_fail"
out=$(run --check-only); rc=$?
eq   "damaged backup: refused"                           "1" "$rc"
has  "damaged backup: says so"                           "damaged or incomplete" "$out"
rm -f "$T/verify_fail"

mkdir -p "$T/backup/2026-11-10_020000_scheduled/pg_tblspc"; ln -s /somewhere "$T/backup/2026-11-10_020000_scheduled/pg_tblspc/16400"
out=$(run --check-only); rc=$?
eq   "backup with a tablespace: refused"                 "1" "$rc"
has  "backup with a tablespace: says why"                "tablespaces" "$out"
rm -rf "$T/backup/2026-11-10_020000_scheduled/pg_tblspc"

echo "== restore-test.sh: TDE passphrase file"
mkdir -p "$T/tde"
printf "data_encryption_key_unwrap_command = 'openssl enc -d -aes-128-cbc -pbkdf2 -pass file:%s/as17.pass -in %%p'\n" "$T/tde" \
    > "$T/backup/2026-11-10_020000_scheduled/postgresql.conf"
out=$(run --check-only); rc=$?
eq   "TDE, passphrase file missing: refused"             "1" "$rc"
has  "TDE, passphrase file missing: names it"            "$T/tde/as17.pass does not exist" "$out"
echo "SECRETPASSPHRASE" > "$T/tde/as17.pass"
: > "$T/calls"
out=$(run --check-only); rc=$?
eq   "TDE, passphrase file present: passes"              "0" "$rc"
hasnt "the passphrase is never printed"                  "SECRETPASSPHRASE" "$out$(cat "$T"/logs/*.log 2>/dev/null)"
has  "TDE: pg_verifybackup skips the (encrypted) WAL"    "--no-parse-wal" "$(calls)"
: > "$T/tde/as17.pass"
out=$(run --check-only); rc=$?
eq   "TDE, passphrase file empty: refused"               "1" "$rc"

echo "== restore-test.sh: failed copies are kept, and block the next run"
reset; mkbackup 2026-11-10_020000_scheduled
mkdir -p "$T/backup/restore-test/2026-11-11_030000_of_2026-11-10_020000_scheduled"
out=$(run --check-only); rc=$?
eq   "a kept failed copy blocks a new test"              "1" "$rc"
has  "says how to clear it"                              "--remove-kept" "$out"
out=$(run --remove-kept); rc=$?
eq   "--remove-kept needs --yes when nobody is there"    "1" "$rc"
eq   "...and deletes nothing without it"                 "1" "$(find "$T/backup/restore-test" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
out=$(run --remove-kept --yes); rc=$?
eq   "--remove-kept --yes: succeeds"                     "0" "$rc"
eq   "...and the kept copy is gone"                      "0" "$(find "$T/backup/restore-test" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
eq   "the real backup is untouched"                      "1" "$([ -f "$T/backup/2026-11-10_020000_scheduled/backup_label" ] && echo 1 || echo 0)"
out=$(run --check-only); rc=$?
eq   "after clearing: tests can run again"               "0" "$rc"

echo "== restore-test.sh: restore, start, replay (step 2)"
reset; mkbackup 2026-11-10_020000_scheduled
socks_before=$(find /tmp -maxdepth 1 -name 'edb-restore-test.*' 2>/dev/null | wc -l | tr -d ' ')
out=$(run); rc=$?
eq   "a good backup: the test passes"                    "0" "$rc"
has  "says it passed"                                    "RESTORE TEST PASSED" "$out"
has  "reports how much WAL was replayed"                 "Replayed 3 archived WAL file(s)" "$out"
has  "the copy was made from the chosen backup"          "of_2026-11-10_020000_scheduled" "$out"
has  "the copy looked like a restore at start: recovery.signal" "recovery.signal" "$(cat "$T/start_facts")"
has  "the copy kept its backup_label"                    "backup_label" "$(cat "$T/start_facts")"
has  "the copy's folder is mode 700"                     "mode=700" "$(cat "$T/start_facts")"
has  "own port"                                          "port=55432" "$(calls)"
has  "never archives"                                    "archive_mode=off" "$(calls)"
has  "restore_command reads the real archive"            "restore_command='cp $T/archive/%f %p'" "$(calls)"
has  "no standby checks"                                 "hot_standby=off" "$(calls)"
has  "no replication"                                    "max_wal_senders=0" "$(calls)"
eq   "the real backup was not touched (no recovery.signal in it)" "0" "$([ -e "$T/backup/2026-11-10_020000_scheduled/recovery.signal" ] && echo 1 || echo 0)"
eq   "the temporary instance is stopped afterwards"      "0" "$([ -f "$T/pg_running" ] && echo 1 || echo 0)"
eq   "no socket folder is left in /tmp"                  "$socks_before" "$(find /tmp -maxdepth 1 -name 'edb-restore-test.*' 2>/dev/null | wc -l | tr -d ' ')"
has  "one audit line in the log"                         "AUDIT" "$(cat "$T"/logs/*.log 2>/dev/null)"

reset; mkbackup 2026-11-10_020000_scheduled; : > "$T/instance_dies"
out=$(run); rc=$?
eq   "instance dies during recovery: the test fails"     "1" "$rc"
has  "says why, and shows the instance log"              "stopped before recovery finished" "$out"
has  "shows the instance's own message"                  "could not locate required checkpoint record" "$out"

reset; mkbackup 2026-11-10_020000_scheduled; : > "$T/never_ready"
out=$(RESTORE_TEST_TIMEOUT_SECS=2 RESTORE_TEST_POLL_SECS=1 run); rc=$?
eq   "recovery never finishes: the test times out"       "1" "$rc"
has  "says it timed out"                                 "Timed out" "$out"
eq   "the instance is stopped after a timeout"           "0" "$([ -f "$T/pg_running" ] && echo 1 || echo 0)"

reset; mkbackup 2026-11-10_020000_scheduled; : > "$T/still_recovery"
out=$(run); rc=$?
eq   "instance still in recovery after it answered: fails" "1" "$rc"
reset; mkbackup 2026-11-10_020000_scheduled; : > "$T/write_fail"
out=$(run); rc=$?
eq   "instance cannot write: fails"                      "1" "$rc"
reset; mkbackup 2026-11-10_020000_scheduled; : > "$T/start_fail"
out=$(run); rc=$?
eq   "pg_ctl cannot start: fails"                        "1" "$rc"
reset; mkbackup 2026-11-10_020000_scheduled; : > "$T/port_busy"
out=$(run); rc=$?
eq   "test port already in use: refused"                 "1" "$rc"
has  "port in use: says so"                              "already answers on port" "$out"
eq   "port in use: nothing was copied"                   "0" "$(find "$T/backup/restore-test" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
