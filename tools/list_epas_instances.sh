#!/usr/bin/env bash
#
# Usage:  ./list_epas_instances.sh        -> print a table of running clusters
#         source list_epas_instances.sh  -> define list_epas_instances() for other scripts
#
# list_epas_instances: one line per running EPAS/PostgreSQL cluster
#   VERSION|PGDATA|PORT|PID|OWNER|MANAGED_BY
#   unknown values are '?'; MANAGED_BY is systemd:<unit> or manual/pg_ctl
# Works as any user; root and the cluster owner see the most (other users cannot
# read inside a data directory). Safe to source from scripts using set -euo pipefail.
#
# The detection itself lives in lib/epas-detect.sh (one implementation for every
# tool); this file only keeps the interface and the table output stable.

# Load the shared detection library: from this checkout, else from the installed toolkit
_lei_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lei_lib in "$_lei_dir/../lib/epas-detect.sh" "${EDB_TOOLKIT_HOME:-/opt/edb_toolkit}/lib/epas-detect.sh"; do
    if [[ -r $_lei_lib ]]; then
        # shellcheck source=../lib/epas-detect.sh
        source "$_lei_lib"
        break
    fi
done
unset _lei_dir _lei_lib
if ! declare -F epas_instances >/dev/null; then
    echo "list_epas_instances.sh: lib/epas-detect.sh not found (next to tools/ or in \${EDB_TOOLKIT_HOME:-/opt/edb_toolkit}/lib)" >&2
    if [[ ${BASH_SOURCE[0]} == "$0" ]]; then exit 1; else return 1; fi
fi

list_epas_instances() {
    local ver data port pid owner mgr rest
    while IFS='|' read -r ver data port pid owner mgr rest; do
        [[ -n $data ]] || continue
        [[ $mgr == pg_ctl ]] && mgr="manual/pg_ctl"
        echo "${ver:-?}|$data|${port:-?}|${pid:-?}|${owner:-?}|$mgr"
    done < <(epas_instances)
    return 0
}

# Run directly -> print a table; when sourced -> only define the function
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    out=$(list_epas_instances)
    if [[ -z $out ]]; then
        echo "No running EPAS/PostgreSQL instances found."
        exit 1
    fi
    # Align columns with awk (no dependency on 'column', which minimal hosts may lack)
    { echo "VERSION|PGDATA|PORT|PID|OWNER|MANAGED_BY"; echo "$out"; } | awk -F'|' '
        { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; nf = NF }
        END { for (r = 1; r <= n; r++) { line = ""
                  for (i = 1; i <= nf; i++) line = line sprintf(i < nf ? "%-" w[i] + 2 "s" : "%s", cell[r, i])
                  print line } }'
    if [[ $out == *'|?|'* ]]; then
        if [[ $EUID -eq 0 ]]; then
            echo "(PORT '?' = port not found in postmaster.pid, the command line or the config files)" >&2
        else
            echo "(PORT '?' = data directory not readable as $(id -un); run as root or the DB owner)" >&2
        fi
    fi
    exit 0
fi
