#!/usr/bin/env bash
# =============================================================================
# tests/common-unit.sh - unit tests for the settings check in lib/common.sh and for
# HA_TOOL and SITE in the 03-patching scripts.
#
# No database, no root, nothing is really started or stopped: sudo, systemctl, pg_isready,
# efm and ip are replaced by fakes that only record how they were called.
# Run:  tests/common-unit.sh   or  make test.   Exit code 0 = all passed.
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
mkdir -p "$T/bin" "$T/logs"

# ---- fakes: every call is written to $T/calls ------------------------------------------------
# sudo: record nothing itself, drop its own options (-n, -u USER) and run the command.
cat > "$T/bin/sudo" <<'FAKE'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
exec "$@"
FAKE
# systemctl:
#   list-units        prints the agents named in $T/agents (one unit per line)
#   is-active UNIT    exit 0 if UNIT is named in $T/active, else 3 (not recorded)
#   anything else     is recorded; it fails (exit 1) if its text is a line of $T/fail
cat > "$T/bin/systemctl" <<FAKE
#!/bin/sh
if [ "\$1" = "list-units" ]; then
    [ -f "$T/agents" ] && while read -r u; do echo "\$u loaded active running EFM agent"; done < "$T/agents"
    exit 0
fi
if [ "\$1" = "is-active" ]; then
    for a in "\$@"; do unit="\$a"; done
    [ -f "$T/active" ] && grep -qx "\$unit" "$T/active" && exit 0
    exit 3
fi
echo "systemctl \$*" >> "$T/calls"
[ -f "$T/fail" ] && grep -qx "\$*" "$T/fail" && exit 1
exit 0
FAKE
printf '#!/bin/sh\necho "dnf $*" >> "%s/calls"\nexit 0\n' "$T" > "$T/bin/dnf"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pg_isready"
printf '#!/bin/sh\necho "efm $*" >> "%s/calls"\nexit 0\n' "$T" > "$T/bin/efm"
printf '#!/bin/sh\necho "ip $*" >> "%s/ipcalls"\nexit 0\n' "$T" > "$T/bin/ip"
# rpm: prints the version in $T/pkgver (fails if the file is missing); psql: prints $T/inrec (default f);
# edb_sqlpatch: recorded.
printf '#!/bin/sh\n[ -f "%s/pkgver" ] || exit 1\ncat "%s/pkgver"\n' "$T" "$T" > "$T/bin/rpm"
printf '#!/bin/sh\necho "psql $*" >> "%s/calls"\ncat "%s/inrec" 2>/dev/null || echo f\n' "$T" "$T" > "$T/bin/psql"
printf '#!/bin/sh\necho "edb_sqlpatch $*" >> "%s/calls"\n[ -f "%s/sqlpatch_fail" ] && exit 1\nexit 0\n' "$T" "$T" > "$T/bin/edb_sqlpatch"
chmod +x "$T"/bin/*

# env_file LINES... - write a config file with the minimum the patching scripts need, plus LINES
env_file() {
    {
        echo 'EPAS_VERSION=17'
        echo 'EFM_VERSION=5.3'
        echo 'SYSTEM_USER=enterprisedb'
        echo 'PRIMARY_PORT=5444'
        echo 'SRC_BINARY_DIR=/nonexistent'
        echo "EFM_BIN=$T/bin/efm"
        echo "TOOLKIT_LOG_DIR=$T/logs"
        printf '%s\n' "$@"
    } > "$T/site.env"
}
# run SCRIPT - run a toolkit script with the fakes first on PATH, not from a terminal (no question asked)
run() {
    : > "$T/calls"; : > "$T/ipcalls"
    env -u TOOLKIT_LOG_FILE -u HA_TOOL -u SITE -u BACKUP_TOOL -u APP_CODE \
        PATH="$T/bin:$PATH" bash "$ROOT/$1" --env "$T/site.env" "${@:2}" </dev/null 2>&1
}
calls() { tr '\n' ';' < "$T/calls"; }
# settings 'commands' - load lib/common.sh and the config file in a clean shell
settings() {
    env -u TOOLKIT_LOG_FILE -u HA_TOOL -u SITE -u BACKUP_TOOL -u APP_CODE \
        PATH="$T/bin:$PATH" bash -c "source '$ROOT/lib/common.sh'; ENV_FILE='$T/site.env'; load_env required; $1" 2>&1
}
rm -f "$T/agents" "$T/active" "$T/fail"

echo "== Settings: defaults and accepted values"
env_file
eq "a config file without the new settings gets the defaults"  "|primary|efm|basebackup" \
   "$(settings 'echo "$APP_CODE|$SITE|$HA_TOOL|$BACKUP_TOOL"' | tail -1)"
env_file 'APP_CODE="PAY-01"' 'SITE="DR"' 'HA_TOOL="None"' 'BACKUP_TOOL="Barman"'
eq "upper case is accepted and stored in lower case"            "PAY-01|dr|none|barman" \
   "$(settings 'echo "$APP_CODE|$SITE|$HA_TOOL|$BACKUP_TOOL"' | tail -1)"

echo "== Settings: a value outside the list stops the script"
env_file 'HA_TOOL="efm2"'
out=$(settings 'echo still-running'); rc=$?
eq "wrong HA_TOOL: exit code 1"            "1" "$rc"
has "wrong HA_TOOL: names the setting"     "HA_TOOL='efm2' (allowed: efm, none)" "$out"
hasnt "wrong HA_TOOL: the script goes no further" "still-running" "$out"
env_file 'SITE="secondary"' 'BACKUP_TOOL="tape"' 'APP_CODE="PAY 01"'
out=$(settings 'echo still-running')
has "wrong SITE reported"                  "SITE='secondary' (allowed: primary, dr)" "$out"
has "wrong BACKUP_TOOL in the same message" "BACKUP_TOOL='tape' (allowed: basebackup, barman, pgbackrest, none)" "$out"
has "wrong APP_CODE in the same message"   "APP_CODE='PAY 01' (letters, digits, _ and - only)" "$out"
env_file 'HA_TOOL="patroni"'
out=$(run modules/03-patching/node-maintenance-stop.sh); rc=$?
eq "a patching script stops on a wrong setting"  "1" "$rc"
eq "... before it calls systemctl"               "" "$(calls)"

down="modules/03-patching/node-maintenance-stop.sh"
up="modules/03-patching/node-maintenance-start.sh"
for site in primary dr; do
    site_line="SITE=\"${site}\""

    echo "== ${site} site, HA_TOOL=efm (the default): as before"
    env_file "$site_line"
    out=$(run "$down"); rc=$?
    eq "shutdown: exit code 0"                  "0" "$rc"
    eq "shutdown: EFM stopped and disabled, then EPAS stopped" \
       "systemctl stop edb-efm-5.3;systemctl disable edb-efm-5.3;systemctl stop edb-as-17;" "$(calls)"
    has "shutdown: audit line names the site"   "Node stopped for maintenance: $(hostname -s) (${site} site)" "$out"
    if [ "$site" = "primary" ]; then
        has   "shutdown: primary site lists the IP addresses"  "ip addr show" "$(cat "$T/ipcalls")"
    else
        eq    "shutdown: DR site does not list IP addresses"   "" "$(cat "$T/ipcalls")"
    fi
    out=$(run "$up"); rc=$?
    eq "startup: exit code 0"                   "0" "$rc"
    has "startup: EPAS started, then EFM enabled and started" \
       "systemctl start edb-as-17;systemctl enable edb-efm-5.3;systemctl start edb-efm-5.3;" "$(calls)"
    has "startup: waits for EFM to report the cluster"  "efm cluster-status efm;" "$(calls)"
    has "startup: audit line names the site"            "Node back in service after maintenance: $(hostname -s) (${site} site)" "$out"

    echo "== ${site} site, HA_TOOL=none: EFM is left alone"
    env_file "$site_line" 'HA_TOOL="none"'
    out=$(run "$down"); rc=$?
    eq "shutdown: exit code 0"                  "0" "$rc"
    eq "shutdown: only EPAS is stopped"         "systemctl stop edb-as-17;" "$(calls)"
    has "shutdown: says the EFM steps were skipped" "HA_TOOL=none: this cluster has no failover manager - EFM steps skipped" "$out"
    out=$(run "$up"); rc=$?
    eq "startup: exit code 0"                   "0" "$rc"
    eq "startup: only EPAS is started"          "systemctl start edb-as-17;" "$(calls)"
    has "startup: says the EFM steps were skipped" "EFM steps skipped" "$out"

    echo "== ${site} site, HA_TOOL=none but an EFM agent is running"
    echo "edb-efm-5.3.service" > "$T/agents"
    out=$(run "$down"); rc=$?
    eq "shutdown: refuses (exit code 1)"        "1" "$rc"
    has "shutdown: names the running agent"     "an EFM agent is running on this host (edb-efm-5.3.service)" "$out"
    eq "shutdown: EPAS is NOT stopped"          "" "$(calls)"
    rm -f "$T/agents"

    echo "== ${site} site: a stop that fails is not ignored"
    env_file "$site_line"
    echo "stop edb-efm-5.3" > "$T/fail"
    out=$(run "$down"); rc=$?
    eq "EFM stop fails: exit code 1"               "1" "$rc"
    eq "EFM stop fails: EPAS is NOT stopped"       "systemctl stop edb-efm-5.3;" "$(calls)"
    has "EFM stop fails: says so"                  "Could not stop edb-efm-5.3. EPAS was NOT stopped" "$out"
    hasnt "EFM stop fails: no audit line"          "[AUDIT]" "$out"
    echo "stop edb-as-17" > "$T/fail"
    out=$(run "$down"); rc=$?
    eq "EPAS stop fails: exit code 1"              "1" "$rc"
    has "EPAS stop fails: node is not ready"       "Could not stop edb-as-17 - this node is NOT ready for maintenance" "$out"
    has "EPAS stop fails: says EFM is already off" "edb-efm-5.3 is already stopped and disabled" "$out"
    hasnt "EPAS stop fails: no audit line"         "[AUDIT]" "$out"
    rm -f "$T/fail"
    echo "edb-as-17" > "$T/active"
    out=$(run "$down"); rc=$?
    eq "EPAS still running after the stop: exit code 1" "1" "$rc"
    has "EPAS still running after the stop: says so"    "edb-as-17 is still running after the stop" "$out"
    hasnt "EPAS still running after the stop: no audit line" "[AUDIT]" "$out"
    rm -f "$T/active"
    out=$(run "$down"); rc=$?
    eq "everything stops: exit code 0"             "0" "$rc"
    has "everything stops: audit line written"     "[AUDIT]" "$out"

    echo "== ${site} site: a start that fails is not ignored"
    echo "start edb-as-17" > "$T/fail"
    out=$(run "$up"); rc=$?
    eq "EPAS start fails: exit code 1"             "1" "$rc"
    eq "EPAS start fails: EFM is NOT enabled or started" "systemctl start edb-as-17;" "$(calls)"
    has "EPAS start fails: says so"                "Could not start edb-as-17 - EFM NOT started" "$out"
    rm -f "$T/fail"
done

echo "== epas-minor-update.sh (for a node without EFM)"
env_file 'HA_TOOL="none"'
echo "edb-efm-5.3.service" > "$T/agents"
out=$(run modules/03-patching/epas-minor-update.sh); rc=$?
eq "EFM agent running: refuses (exit code 1)"      "1" "$rc"
has "EFM agent running: names the agent"           "An EFM agent is running on this host (edb-efm-5.3.service)" "$out"
has "EFM agent running: points to the EFM script"  "epas-minor-update-efm.sh" "$out"
eq "EFM agent running: nothing is stopped"         "" "$(calls)"
env_file 'HA_TOOL="efm"'
out=$(run modules/03-patching/epas-minor-update.sh); rc=$?
eq "refused on an EFM node whatever HA_TOOL says"  "1" "$rc"
eq "... and nothing is stopped"                    "" "$(calls)"
rm -f "$T/agents"
if [ "$(id -u)" -ne 0 ]; then
    out=$(run modules/03-patching/epas-minor-update.sh)
    has "no agent: the EFM check passes (next stop is the root check)" "Run as root" "$out"
fi

echo "== epas-minor-update-efm.sh"
env_file 'HA_TOOL="none"'
out=$(run modules/03-patching/epas-minor-update-efm.sh); rc=$?
eq "HA_TOOL=none: refuses (exit code 1)"        "1" "$rc"
has "HA_TOOL=none: points to the single-node script" "epas-minor-update.sh" "$out"
eq "HA_TOOL=none: nothing is stopped"           "" "$(calls)"

echo "== The old names are gone"
for old in primary_site/patch-primary-shutdown.sh primary_site/patch-primary-startup.sh dr_site/patch-dr-shutdown.sh \
           dr_site/patch-dr-startup.sh epas-minor-patch-update.sh efm-rolling-minor-patch.sh; do
    [[ ! -e "modules/03-patching/$old" ]]; eq "no $old" 0 $?
done
out=$(grep -rlE 'patch-(primary|dr)-(shutdown|startup)|epas-minor-patch-update|efm-rolling-minor-patch' \
      --include='*.sh' --include='*.example' --include='epas-automation' modules lib tools conf 2>/dev/null | tr '\n' ' ')
eq "no script or config still refers to an old name" "" "$out"

echo "== confirm_destructive (lib/common.sh)"
env_file
out=$(settings 'confirm_destructive "wipe the test host" </dev/null; echo REACHED'); rc=$?
hasnt "no terminal, no --yes: stops before the action" "REACHED" "$out"
has   "no terminal, no --yes: says --yes is needed"     "needs --yes" "$out"
out=$(settings 'ASSUME_YES=1; confirm_destructive "wipe the test host"; echo REACHED')
has   "--yes: goes ahead"                               "REACHED" "$out"
has   "--yes: writes an audit line"                     "accepted with --yes" "$(cat "$T"/logs/* 2>/dev/null)"

echo "== tools/epas_full_uninstall.sh"
out=$(run tools/epas_full_uninstall.sh); rc=$?
if [ "$(id -u)" -ne 0 ]; then
    eq  "not root: refuses (exit code 1)"               "1" "$rc"
    has "not root: says so"                             "Run as root" "$out"
    eq  "not root: nothing is stopped"                  "" "$(calls)"
fi
grep -q 'confirm_destructive' tools/epas_full_uninstall.sh; eq "asks for the host name before deleting" 0 $?
out=$(grep -nE 'rm -rf.*(DATA_TOP|WAL_TOP|ARCHIVE_TOP|BACKUP_TOP|LOG_TOP|BINARY_TOP|/pgdata|/pgwal|/pgarchive|/pgbackup|/pglog)' tools/epas_full_uninstall.sh)
eq "never deletes the cluster mounts"                   "" "$out"

echo "== Patching with the sysadmin's dnf in the middle (stop -> dnf -> start --patched)"
rm -f "$T/agents" "$T/active" "$T/fail" "$T/inrec" "$T/sqlpatch_fail"; rm -rf "$T/logs/patching"
env_file
echo "17.5-1" > "$T/pkgver"
out=$(run "$down"); rc=$?
eq  "stop: exit code 0"                                  "0" "$rc"
eq  "stop: notes the installed package version"          "17.5-1" "$(cat "$T"/logs/patching/*_edb-as-17.version 2>/dev/null)"
has "stop: says so"                                      "Installed edb-as17-server is 17.5-1" "$out"
has "stop: no VIP set, no VIP check"                     "VIP_ADDRESS is not set" "$out"
out=$(run "$up" --patched); rc=$?
eq  "start --patched, dnf has not run: exit code 1"      "1" "$rc"
has "... says the packages did not change"               "is still 17.5-1" "$out"
eq  "... and starts nothing"                             "" "$(calls)"
echo "17.6-1" > "$T/pkgver"
out=$(run "$up" --patched); rc=$?
eq  "start --patched, packages changed: exit code 0"     "0" "$rc"
has "... reports the change"                             "Packages changed: 17.5-1 -> 17.6-1" "$out"
has "... EPAS started, edb_sqlpatch runs, THEN EFM starts" "systemctl start edb-as-17;psql" "$(calls)"
has "... edb_sqlpatch before EFM is enabled"             "edb_sqlpatch -af;systemctl enable edb-efm-5.3" "$(calls)"
echo t > "$T/inrec"
out=$(run "$up" --patched); rc=$?
eq  "start --patched on a standby: exit code 0"          "0" "$rc"
has "... says edb_sqlpatch is for the primary only"      "standby: edb_sqlpatch runs on the primary only" "$out"
hasnt "... and does not run edb_sqlpatch"                "edb_sqlpatch -af" "$(calls)"
echo f > "$T/inrec"; : > "$T/sqlpatch_fail"
out=$(run "$up" --patched); rc=$?
eq  "edb_sqlpatch fails: exit code 1"                    "1" "$rc"
has "... says EFM was NOT started"                       "EFM NOT started" "$out"
hasnt "... and EFM is not started"                       "systemctl start edb-efm-5.3" "$(calls)"
rm -f "$T/sqlpatch_fail"; rm -rf "$T/logs/patching"
out=$(run "$up" --patched); rc=$?
eq  "start --patched with no note from the stop: exit code 1" "1" "$rc"
has "... explains where the note comes from"             "node-maintenance-stop.sh writes it" "$out"
eq  "... and starts nothing"                             "" "$(calls)"
out=$(run "$up"); rc=$?
eq  "start without --patched (plain reboot): exit code 0" "0" "$rc"
hasnt "... no edb_sqlpatch, no package check"            "edb_sqlpatch" "$(calls)"
out=$(run "$up" --nonsense); rc=$?
eq  "unknown option: exit code 1"                        "1" "$rc"
env_file 'VIP_ADDRESS=10.1.2.3' 'VIP_INTERFACE=eth9'
out=$(run "$down"); rc=$?
has "stop with VIP_ADDRESS set: looks at that interface" "ip addr show eth9" "$(cat "$T/ipcalls")"
has "... and reports it (information only, no question)" "VIP 10.1.2.3 is not on this node" "$out"
eq  "... exit code 0"                                    "0" "$rc"
rm -f "$T/pkgver" "$T/inrec"

echo "== run_as_db_user (the DBA has no 'sudo -u enterprisedb' rule)"
rdu() { bash -c "source '$ROOT/lib/common.sh'; sudo() { echo \"SUDO \$*\"; }; SYSTEM_USER='$1'; run_as_db_user echo hello" 2>&1; }
eq  "already the database user: runs directly, no sudo"   "hello" "$(rdu "$(id -un)")"
eq  "another user (e.g. root): goes through sudo -u"      "SUDO -u nobody-else echo hello" "$(rdu nobody-else)"

echo "== Template (conf/site.env.example)"
out=$(bash -c 'set -u; source conf/site.env.example; echo "$APP_CODE|$SITE|$HA_TOOL|$BACKUP_TOOL"' 2>&1)
eq "standard values"                            "|primary|efm|basebackup" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
