#!/usr/bin/env bash
# =============================================================================
# tests/common-unit.sh - unit tests for the settings check in lib/common.sh and for
# HA_TOOL in the 03-patching scripts.
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
# systemctl: 'list-units' prints the agents named in $T/agents (one unit per line); the rest is recorded.
cat > "$T/bin/systemctl" <<FAKE
#!/bin/sh
if [ "\$1" = "list-units" ]; then
    [ -f "$T/agents" ] && while read -r u; do echo "\$u loaded active running EFM agent"; done < "$T/agents"
    exit 0
fi
echo "systemctl \$*" >> "$T/calls"
FAKE
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pg_isready"
printf '#!/bin/sh\necho "efm $*" >> "%s/calls"\nexit 0\n' "$T" > "$T/bin/efm"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ip"
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
    : > "$T/calls"
    env -u TOOLKIT_LOG_FILE -u HA_TOOL -u SITE -u BACKUP_TOOL -u APP_CODE \
        PATH="$T/bin:$PATH" bash "$ROOT/$1" --env "$T/site.env" </dev/null 2>&1
}
calls() { tr '\n' ';' < "$T/calls"; }
# settings 'commands' - load lib/common.sh and the config file in a clean shell
settings() {
    env -u TOOLKIT_LOG_FILE -u HA_TOOL -u SITE -u BACKUP_TOOL -u APP_CODE \
        PATH="$T/bin:$PATH" bash -c "source '$ROOT/lib/common.sh'; ENV_FILE='$T/site.env'; load_env required; $1" 2>&1
}
rm -f "$T/agents"

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
out=$(run modules/03-patching/primary_site/patch-primary-shutdown.sh); rc=$?
eq "a patching script stops on a wrong setting"  "1" "$rc"
eq "... before it calls systemctl"               "" "$(calls)"

for site in primary dr; do
    down="modules/03-patching/${site}_site/patch-${site}-shutdown.sh"
    up="modules/03-patching/${site}_site/patch-${site}-startup.sh"

    echo "== ${site} site, HA_TOOL=efm (the default): as before"
    env_file
    out=$(run "$down"); rc=$?
    eq "shutdown: exit code 0"                  "0" "$rc"
    eq "shutdown: EFM stopped and disabled, then EPAS stopped" \
       "systemctl stop edb-efm-5.3;systemctl disable edb-efm-5.3;systemctl stop edb-as-17;" "$(calls)"
    out=$(run "$up"); rc=$?
    eq "startup: exit code 0"                   "0" "$rc"
    has "startup: EPAS started, then EFM enabled and started" \
       "systemctl start edb-as-17;systemctl enable edb-efm-5.3;systemctl start edb-efm-5.3;" "$(calls)"

    echo "== ${site} site, HA_TOOL=none: EFM is left alone"
    env_file 'HA_TOOL="none"'
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
done

echo "== efm-rolling-minor-patch.sh"
env_file 'HA_TOOL="none"'
out=$(run modules/03-patching/efm-rolling-minor-patch.sh); rc=$?
eq "HA_TOOL=none: refuses (exit code 1)"        "1" "$rc"
has "HA_TOOL=none: points to the single-node script" "epas-minor-patch-update.sh" "$out"
eq "HA_TOOL=none: nothing is stopped"           "" "$(calls)"

echo "== Template (conf/site.env.example)"
out=$(bash -c 'set -u; source conf/site.env.example; echo "$APP_CODE|$SITE|$HA_TOOL|$BACKUP_TOOL"' 2>&1)
eq "standard values"                            "|primary|efm|basebackup" "$out"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
