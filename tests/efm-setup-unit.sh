#!/usr/bin/env bash
# =============================================================================
# tests/efm-setup-unit.sh - unit tests for modules/05-efm/efm-setup.sh
# (the DBA prepares the EFM files; the sysadmin installs them).
# No database, no root, no EFM, no dnf: rpm and efm are fakes. Run: tests/efm-setup-unit.sh or make test.
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
mkdir -p "$T/bin" "$T/conf" "$T/logs" "$T/as17/bin" "$T/data17"
printf '#!/bin/sh\nexit 0\n' > "$T/as17/bin/pg_ctl"; chmod +x "$T/as17/bin/pg_ctl"
# fake rpm: installed only if $T/pkg exists
printf '#!/bin/sh\n[ -f "%s/pkg" ]\n' "$T" > "$T/bin/rpm"
# fake efm: 'encrypt' prints a hex string, or fails if $T/encfail exists
cat > "$T/efm" <<FAKE
#!/bin/sh
if [ "\$1" = encrypt ]; then [ -f "$T/encfail" ] && exit 1; echo "Please enter the password:"; echo "ABCDEF0123456789"; exit 0; fi
exit 0
FAKE
chmod +x "$T/bin/rpm" "$T/efm"
# the package templates and unit
printf '# template\nbind.address=\nadmin.port=\nis.witness=\ndb.port=\nping.server.ip=8.8.8.8\n' > "$T/conf/efm.properties.in"
printf '# nodes template\n' > "$T/conf/efm.nodes.in"
printf '[Service]\nEnvironment=CLUSTER=efm\nPIDFile=/run/efm-5.3/efm.pid\n' > "$T/efm.service"
cat > "$T/site.env" <<EOF
EFM_VERSION=5.3
EPAS_VERSION=17
SYSTEM_USER=$(id -un)
SERVICE_NAME=edb-as-17
SRC_BINARY_DIR=$T/as17
DATA_TOP=$T/data17
PRIMARY_PORT=5444
PRIMARY_HOST=10.0.0.1
STANDBY_HOST=10.0.0.2
WITNESS_HOST=10.0.0.3
EFM_PING_SERVER_IP=10.0.0.254
EFM_SERVICE=edb-efm-5.3
TOOLKIT_LOG_DIR=$T/logs
EOF
run() {
    env -u TOOLKIT_LOG_FILE PATH="$T/bin:$PATH" EFM_CONF_DIR="$T/conf" EFM_BIN="$T/efm" EFM_PKG_UNIT="$T/efm.service" \
        bash "$ROOT/modules/05-efm/efm-setup.sh" --env "$T/site.env" --yes "$@" </dev/null 2>&1
}
STG="$T/logs/efm/efm"

echo "== the package is not installed: the sysadmin has to do that first"
rm -f "$T/pkg"
out=$(run --role primary); rc=$?
eq  "exit code 1"                                   "1" "$rc"
has "names the dnf command for the sysadmin"        "dnf install -y edb-efm53" "$out"

echo "== first run: files are built in the staging folder, /etc (here: conf) is untouched"
touch "$T/pkg"; ls "$T/conf" > "$T/conf.before"
out=$(EFMPASS=Secret1 run --role primary); rc=$?
eq  "exit code 0"                                   "0" "$rc"
eq  "nothing was written to the EFM config folder"  "$(cat "$T/conf.before")" "$(ls "$T/conf")"
has "bind.address of the primary"                   "bind.address=10.0.0.1:7800" "$(cat "$STG/efm.properties")"
has "is.witness=false"                              "is.witness=false" "$(cat "$STG/efm.properties")"
has "db.bin from the config"                        "db.bin=$T/as17/bin" "$(cat "$STG/efm.properties")"
has "ping server from the config"                   "ping.server.ip=10.0.0.254" "$(cat "$STG/efm.properties")"
has "encrypted password stored"                     "db.password.encrypted=ABCDEF0123456789" "$(cat "$STG/efm.properties")"
eq  "nodes file lists all three nodes"              "10.0.0.1:7800 10.0.0.2:7800 10.0.0.3:7800" "$(tr '\n' ' ' < "$STG/efm.nodes" | sed 's/ $//')"
eq  "properties file is mode 600"                   "600" "$(stat -c '%a' "$STG/efm.properties")"
eq  "staging folder is mode 700"                    "700" "$(stat -c '%a' "$STG")"
has "sysadmin: install the properties file"         "install -o efm -g efm -m 600 $STG/efm.properties $T/conf/efm.properties" "$out"
has "sysadmin: install the nodes file"              "install -o efm -g efm -m 600 $STG/efm.nodes $T/conf/efm.nodes" "$out"
hasnt "the password is never printed"               "Secret1" "$out"
has "DBA starts the agent through sudo"             "sudo systemctl enable edb-efm-5.3" "$out"

echo "== after the sysadmin installed the files: 'already installed', no root step"
cp "$STG/efm.properties" "$T/conf/efm.properties"; cp "$STG/efm.nodes" "$T/conf/efm.nodes"
out=$(run --role primary); rc=$?
eq  "exit code 0"                                   "0" "$rc"
has "properties: already installed"                 "efm.properties: already installed" "$out"
has "nodes: already installed"                      "efm.nodes: already installed" "$out"
has "no root step needed"                           "no root step is needed" "$out"
has "the installed password is kept (blank input)"  "db.password.encrypted=ABCDEF0123456789" "$(cat "$STG/efm.properties")"

echo "== a hand edit in the installed file is shown, and a backup is part of the plan"
echo "ping.server.ip=1.2.3.4" >> "$T/conf/efm.properties"
out=$(run --role primary)
has "shows the line that would be replaced"         "ping.server.ip=1.2.3.4" "$out"
has "plan: backup first"                            "cp -a $T/conf/efm.properties $T/conf/efm.properties.bak." "$out"
cp "$STG/efm.properties" "$T/conf/efm.properties"

echo "== standby and witness"
out=$(run --role standby)
has "standby binds its own address"                 "bind.address=10.0.0.2:7800" "$(cat "$STG/efm.properties")"
out=$(run --role witness)
has "witness binds the witness address"             "bind.address=10.0.0.3:7800" "$(cat "$STG/efm.properties")"
has "witness: is.witness=true"                      "is.witness=true" "$(cat "$STG/efm.properties")"
hasnt "witness: no database settings"               "db.bin=" "$(cat "$STG/efm.properties")"

echo "== a second cluster gets its own unit file"
out=$(EFM_BIND_PORT=7801 EFM_ADMIN_PORT=7810 run --role primary --cluster pay); rc=$?
eq  "exit code 0"                                   "0" "$rc"
has "unit names the cluster"                        "Environment=CLUSTER=pay" "$(cat "$T/logs/efm/pay/efm-pay.service")"
has "pid file names the cluster"                    "PIDFile=/run/efm-5.3/pay.pid" "$(cat "$T/logs/efm/pay/efm-pay.service")"
has "sysadmin installs the unit as root"            "install -o root -g root -m 644 $T/logs/efm/pay/efm-pay.service /etc/systemd/system/efm-pay.service" "$out"
has "sysadmin reloads systemd"                      "systemctl daemon-reload" "$out"

echo "== port clash with another cluster on the node"
out=$(run --role primary --cluster pay); rc=$?
eq  "same ports as the installed 'efm' cluster: exit code 1" "1" "$rc"
has "names the clash"                               "admin.port 7809 is already used by efm.properties" "$out"

echo "== 'efm encrypt' does not work for the DBA"
touch "$T/encfail"
out=$(EFMPASS=Secret1 EFM_BIND_PORT=7802 EFM_ADMIN_PORT=7811 run --role primary --cluster enc); rc=$?
eq  "exit code 0 (a warning, not a failure)"        "0" "$rc"
has "says who can do it"                            "Have the sysadmin (or the efm user) run it" "$out"
hasnt "no password hash in the staged file"         "db.password.encrypted=ABC" "$(cat "$T/logs/efm/enc/enc.properties")"
rm -f "$T/encfail"

echo "== removed options and refusals"
out=$(run --role primary --no-install); rc=$?
eq  "--no-install: exit code 1"                     "1" "$rc"
has "--no-install: says the sysadmin installs"      "never installs" "$out"
out=$(run --role primary --start); rc=$?
eq  "--start: exit code 1"                          "1" "$rc"
has "--start: says what to do instead"              "sudo systemctl enable" "$out"
out=$(run); rc=$?
eq  "no --role without a terminal: exit code 1"     "1" "$rc"
grep -q 'require_root' modules/05-efm/efm-setup.sh; eq "the script no longer asks for root" 1 $?
grep -qE '^\s*(dnf|chown|systemctl)\b' modules/05-efm/efm-setup.sh; eq "the script calls no dnf, chown or systemctl itself" 1 $?

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
