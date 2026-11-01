#!/usr/bin/env bash
# =============================================================================
# tests/epas-detect-unit.sh - unit tests for lib/epas-detect.sh
#
# No database, no root: every input is a small file created in a temp folder,
# so this runs anywhere (laptop, CI). Run:  tests/epas-detect-unit.sh   or  make test
# Exit code 0 = all passed.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
LIB="$PWD/lib/epas-detect.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: [%s]\n        got:      [%s]\n' "$1" "$2" "$3"; }
eq()   { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }      # eq NAME EXPECTED ACTUAL
yes_() { if "${@:2}"; then ok "$1"; else bad "$1" "true" "false"; fi; }         # yes_ NAME command...
no_()  { if "${@:2}"; then bad "$1" "false" "true"; else ok "$1"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
echo "== Loading the library"
out=$(bash -c "source '$LIB'" 2>&1); rc=$?
eq "loads with no output"               "0:" "$rc:$out"
out=$(bash -euo pipefail -c "source '$LIB'; echo loaded" 2>&1)
eq "loads under set -euo pipefail"      "loaded" "$out"
out=$(bash -c "o1=\$(set +o); source '$LIB'; o2=\$(set +o); [[ \$o1 == \"\$o2\" ]] && echo same" 2>&1)
eq "changes no shell options"           "same" "$out"
out=$(bash "$LIB" 2>&1); rc=$?
eq "running it directly is refused"     "2" "$rc"

# shellcheck source=../lib/epas-detect.sh
source "$LIB"

# -----------------------------------------------------------------------------
echo "== Config files (epas_conf_get)"
D=$TMP/data; mkdir -p "$D/conf.d" "$D/extra"
cat > "$D/postgresql.conf" <<'EOF'
# a comment: port = 1111
port = 5432                      # initdb default
Log_Directory='pg_log'           # names are case-insensitive
log_line_prefix = '%m [%p] # not a comment %u '
include_dir = 'conf.d'           # files here override the lines above
shared_buffers 128MB             # '=' is optional
include_if_exists = 'missing.conf'
include = 'extra/after.conf'
EOF
printf "port = 5444\nlog_directory = 'log'\n" > "$D/conf.d/01-network.conf"
printf "port = 5445\n"                       > "$D/conf.d/02-later.conf"
printf "port = 9999\nwork_mem = 1MB\n"       > "$D/conf.d/.hidden.conf"     # hidden: must be ignored
printf "port = 9998\nwork_mem = 2MB\n"       > "$D/conf.d/notes.txt"        # not *.conf: must be ignored
printf "log_directory = 'it''s logs'\n"      > "$D/extra/after.conf"
eq "last setting wins, conf.d in C order"   "5445" "$(epas_conf_get "$D" port)"
eq "hidden and non-.conf files ignored"     "" "$(epas_conf_get "$D" work_mem)"
eq "parameter names are case-insensitive"    "5445" "$(epas_conf_get "$D" PORT)"
eq "hidden files ignored with dotglob on"   "" "$(shopt -s dotglob; epas_conf_get "$D" work_mem)"
eq "include after include_dir wins"         "it's logs" "$(epas_conf_get "$D" log_directory)"
eq "'#' inside quotes is not a comment"     "%m [%p] # not a comment %u " "$(epas_conf_get "$D" log_line_prefix)"
eq "'=' is optional"                        "128MB" "$(epas_conf_get "$D" shared_buffers)"
printf "port = '6000'\n" > "$D/postgresql.auto.conf"
eq "postgresql.auto.conf wins over all"     "6000" "$(epas_conf_get "$D" port)"
eq "unset parameter -> empty"               "" "$(epas_conf_get "$D" max_connections)"
eq "missing directory -> empty"             "" "$(epas_conf_get "$TMP/nope" port)"
printf "include = 'loop.conf'\n" > "$D/loop.conf"
printf "include = 'loop.conf'\n" >> "$D/postgresql.auto.conf"
eq "include loop does not hang"             "6000" "$(timeout 10 bash -c "source '$LIB'; epas_conf_get '$D' port")"

# -----------------------------------------------------------------------------
echo "== Port from config, no running server (epas_port)"
printf "port = 5446\n" > "$D/postgresql.auto.conf"
eq "port + source"                          $'5446\tconfig files' "$(epas_port "$D")"
eq "unknown port -> empty"                  "" "$(epas_port "$TMP/nope")"

# -----------------------------------------------------------------------------
echo "== Version, role, TDE"
echo 17 > "$D/PG_VERSION"
eq "version from PG_VERSION"                "17" "$(epas_version "$D")"
eq "PG_VERSION wins over binary path"       "17" "$(epas_version "$D" /usr/edb/as15/bin)"
eq "version from EPAS binary path"          "16" "$(epas_version "$TMP/nope" /u001/binary/as16/bin)"
eq "version from community path (RHEL)"     "15" "$(epas_version "$TMP/nope" /usr/pgsql-15/bin)"
eq "version from community path (Debian)"   "14" "$(epas_version "$TMP/nope" /usr/lib/postgresql/14/bin)"
eq "no clue -> empty"                       "" "$(epas_version "$TMP/nope" /opt/bin)"
eq "role primary"                           "primary" "$(epas_role "$D")"
touch "$D/standby.signal"
eq "role standby"                           "standby" "$(epas_role "$D")"
eq "role of missing dir"                    "unknown" "$(epas_role "$TMP/nope")"
eq "TDE no"                                 "no" "$(epas_tde "$D")"
mkdir -p "$D/pg_encryption"; touch "$D/pg_encryption/key.bin"
eq "TDE yes"                                "yes" "$(epas_tde "$D")"
eq "nothing running -> stopped"             "stopped" "$(epas_manager "$D")"
eq "nothing running -> no PID"              "" "$(epas_running_pid "$D")"

# -----------------------------------------------------------------------------
echo "== Installed versions"
mkdir -p "$TMP/edb/as15/bin" "$TMP/edb/as17/bin" "$TMP/edb/as16/bin" "$TMP/edb/asX/bin"
touch "$TMP/edb/as15/bin/edb-postgres" "$TMP/edb/as17/bin/psql" "$TMP/edb/asX/bin/psql"
chmod +x "$TMP/edb/as15/bin/edb-postgres" "$TMP/edb/as17/bin/psql" "$TMP/edb/asX/bin/psql"
eq "only trees with binaries, numeric, sorted" "15 17" "$(epas_installed_versions "$TMP/edb" | paste -sd' ' -)"

# -----------------------------------------------------------------------------
echo "== Registry (read side)"
R=$TMP/epastab
cat > "$R" <<'EOF'
# header comment
as17:17:/u001/data/as17:5444:edb-as-17:PROD
as17_rpt:17:/u001/data/as17_rpt:5446:-:PROD

garbage without enough fields
as15:15:/u001/data/as15:5445:edb-as-15:DEV:extra-field
EOF
printf 'as16:16:/u001/data/as16:5447:-:SIT\r\n' >> "$R"
eq "well-formed lines only, CRLF tolerated" \
   "as17|17|/u001/data/as17|5444|edb-as-17|PROD as17_rpt|17|/u001/data/as17_rpt|5446|-|PROD as16|16|/u001/data/as16|5447|-|SIT" \
   "$(epas_registry_entries "$R" | paste -sd' ' -)"
eq "get one entry"                          "as17_rpt|17|/u001/data/as17_rpt|5446|-|PROD" "$(epas_registry_get as17_rpt "$R")"
eq "get unknown -> empty"                   "" "$(epas_registry_get as99 "$R")"
eq "missing registry -> empty"              "" "$(epas_registry_entries "$TMP/none")"
eq "EPASTAB overrides the default path"     "$R" "$(EPASTAB=$R epas_registry_file)"
eq "default path"                           "/etc/edb/toolkit/epastab" "$(unset EPASTAB; epas_registry_file)"

# -----------------------------------------------------------------------------
echo "== Validation"
yes_ "name as17"            epas_is_valid_name as17
yes_ "name as17_rpt"        epas_is_valid_name as17_rpt
no_  "name AS17"            epas_is_valid_name AS17
no_  "name as7"             epas_is_valid_name as7
no_  "name as17-rpt"        epas_is_valid_name as17-rpt
no_  "name too long"        epas_is_valid_name as17_abcdefghijklmnopqrstuvwxyz0123
yes_ "tag PROD"             epas_is_valid_tag PROD
no_  "tag prod (stored upper case)" epas_is_valid_tag prod
no_  "tag QA"               epas_is_valid_tag QA
yes_ "port 5444"            epas_is_valid_port 5444
no_  "port 0"               epas_is_valid_port 0
no_  "port 65536"           epas_is_valid_port 65536
no_  "port 54a4"            epas_is_valid_port 54a4

# -----------------------------------------------------------------------------
echo "== Strict-mode safety: every query function under set -euo pipefail"
out=$(bash -euo pipefail -c "
    source '$LIB'
    epas_conf_get '$TMP/nope' port; epas_port '$TMP/nope'; epas_version '$TMP/nope'
    epas_role '$TMP/nope'; epas_tde '$TMP/nope'; epas_live_pid '$TMP/nope'
    epas_running_pid '$TMP/nope'; epas_manager '$TMP/nope'; epas_postmaster_pids
    epas_instances; epas_installed_versions '$TMP/nope'; epas_unit_pgdata nosuch.service
    epas_primary_ip; epas_subnet; epas_registry_entries '$TMP/none'; epas_registry_get x '$TMP/none'
    epas_pid_datadir 999999999; epas_pid_bindir 999999999; epas_pid_unit 999999999; epas_pid_owner 999999999
    echo survived" 2>&1 | tail -n1)
eq "no query function aborts a strict script" "survived" "$out"

echo
echo "Result: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
