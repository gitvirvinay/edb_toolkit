#!/usr/bin/env bash
# =============================================================================
# tests/logger-unit.sh - unit tests for lib/logger.sh (where toolkit messages go)
#
# No database, no root: log directories are temporary folders, and 'sudo' and 'logger'
# are replaced by fakes that only record that they were called.
# Run:  tests/logger-unit.sh   or  make test.   Exit code 0 = all passed.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
LIB="$PWD/lib/logger.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: [%s]\n        got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()  { if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "...$2..." "$3"; fi; }
hasnt(){ if [[ $3 != *"$2"* ]]; then ok "$1"; else bad "$1" "no $2" "$3"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/logs" "$T/mount/toolkit"

# Fakes: record every call in $T/calls instead of doing anything.
printf '#!/bin/sh\necho "sudo $*" >> "%s/calls"\nexit 1\n'   "$T" > "$T/bin/sudo"
printf '#!/bin/sh\necho "logger $*" >> "%s/calls"\n'         "$T" > "$T/bin/logger"
chmod +x "$T/bin/sudo" "$T/bin/logger"

# run SETTINGS 'commands' - load the library in a clean shell with the fakes first on PATH.
# Settings the developer may have exported are removed so they cannot change the result.
run() {
    env -u TOOLKIT_LOG_DIR -u TOOLKIT_LOG_FILE -u TOOLKIT_SYSLOG -u LOG_MOUNT \
        PATH="$T/bin:$PATH" bash -c "$1 source '$LIB'; $2" unit-test.sh
}
calls() { cat "$T/calls" 2>/dev/null; : > "$T/calls"; }
: > "$T/calls"

echo "== Loading the library"
out=$(run "" "echo loaded" 2>&1)
eq "loads under its own 'set -euo pipefail'"  "loaded" "$out"
out=$(grep -cE '^[^#]*\b(sudo|chmod)\b' "$LIB")
eq "the library contains no sudo and no chmod" "0" "$out"

echo "== Which directory"
eq "TOOLKIT_LOG_DIR wins"            "/a/b"            "$(run "TOOLKIT_LOG_DIR=/a/b LOG_MOUNT=/pglog;" "log_dir" 2>&1)"
eq "else <LOG_MOUNT>/toolkit"        "/x/toolkit"      "$(run "LOG_MOUNT=/x;" "log_dir" 2>&1)"
eq "LOG_MOUNT not set -> standard"   "/pglog/toolkit"  "$(run "" "log_dir" 2>&1)"
eq "LOG_MOUNT empty -> no directory" ""                "$(run "LOG_MOUNT='';" "log_dir" 2>&1)"

echo "== A writable directory: one file per run"
out=$(run "TOOLKIT_LOG_DIR='$T/logs';" "log_info 'first message'; log_audit 'did something'; log_file" 2>&1)
has "message printed on the screen"  "[INFO] [unit-test.sh] first message" "$out"
file=$(tail -1 <<<"$out")
n=$(find "$T/logs" -type f | wc -l | tr -d ' ')
eq "exactly one file created"        "1" "$n"
[[ ${file##*/} =~ ^[0-9]{8}-[0-9]{6}_unit-test_[0-9]+\.log$ ]]; eq "file name is <date>-<time>_<script>_<pid>.log" 0 $?
body=$(cat "$file" 2>/dev/null)
has "info line is in the file"       "[INFO] [unit-test.sh] first message" "$body"
has "audit line is in the file"      "[AUDIT] [unit-test.sh] did something" "$body"
eq "file mode is 640"                "640" "$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")"
eq "sudo was never called"           "" "$(calls)"
rm -f "$T"/logs/*

echo "== LOG_MOUNT from the settings"
out=$(run "LOG_MOUNT='$T/mount';" "log_info 'via mount'; log_file" 2>&1)
has "file is under <LOG_MOUNT>/toolkit"  "$T/mount/toolkit/" "$(tail -1 <<<"$out")"
rm -f "$T"/mount/toolkit/*

echo "== Settings loaded after the first message (what load_env does)"
out=$(run "LOG_MOUNT='';" "log_info 'early line' 2>/dev/null; TOOLKIT_LOG_DIR='$T/logs'; log_init; log_info 'late line'; cat \"\$(log_file)\"" 2>&1)
body=${out#*late line}
has "the early message reaches the file"  "early line" "$body"
has "the late message reaches the file"   "late line"  "$body"
eq "still one file"                       "1" "$(find "$T/logs" -type f | wc -l | tr -d ' ')"
rm -f "$T"/logs/*

echo "== Directory missing: the run still works"
out=$(run "TOOLKIT_LOG_DIR='$T/nowhere';" "log_info 'one'; log_warn 'two'; echo rc=\$?" 2>"$T/err"); rc=$?
err=$(cat "$T/err")
eq "exit code 0"                          "0" "$rc"
has "messages still printed"              "[WARN] [unit-test.sh] two" "$out"
has "says there is no log file"           "No log file for this run: '$T/nowhere'" "$err"
eq "says it only once"                    "1" "$(grep -c 'No log file' "$T/err")"
[[ ! -e "$T/nowhere" ]]; eq "does not create the directory" 0 $?
eq "sudo was never called"                "" "$(calls)"

echo "== A script started by another toolkit script"
cat > "$T/child.sh" <<CHILD
#!/usr/bin/env bash
source '$LIB'
log_info 'from the child'
CHILD
out=$(run "TOOLKIT_LOG_DIR='$T/logs';" "log_info 'from the parent'; bash '$T/child.sh' >/dev/null; cat \"\$(log_file)\"" 2>&1)
has "child wrote to the parent's file"    "[child.sh] from the child" "${out#*from the parent}"
eq "still one file"                       "1" "$(find "$T/logs" -type f | wc -l | tr -d ' ')"
rm -f "$T"/logs/*

echo "== Syslog"
run "TOOLKIT_LOG_DIR='$T/logs';" "log_info 'quiet'; log_audit 'quiet too'" >/dev/null 2>&1
eq "off by default"                       "" "$(calls)"
run "TOOLKIT_LOG_DIR='$T/logs'; TOOLKIT_SYSLOG=yes;" "log_info 'loud'; log_audit 'changed x'" >/dev/null 2>&1
c=$(calls)
has "TOOLKIT_SYSLOG=yes: info sent"       "logger -p local0.info -t edb-toolkit [unit-test.sh] loud" "$c"
has "TOOLKIT_SYSLOG=yes: audit sent"      "logger -p local0.notice -t edb-toolkit-audit [unit-test.sh] changed x" "$c"

echo "== Template (conf/site.env.example)"
out=$(bash -c 'set -u; source conf/site.env.example; echo "$TOOLKIT_LOG_DIR|$TOOLKIT_SYSLOG"' 2>&1)
eq "standard values"                      "/pglog/toolkit|no" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
