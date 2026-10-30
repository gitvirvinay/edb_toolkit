#!/usr/bin/env bash
#
# Usage:  ./list_epas_instances.sh        -> print a table of running clusters
#         source list_epas_instances.sh  -> define list_epas_instances() for other scripts
#
# list_epas_instances: one line per running EPAS/PostgreSQL cluster
#   VERSION|PGDATA|PORT|PID|OWNER|MANAGED_BY
# Works as any user; PORT may be "?" for a normal user (postmaster.pid is 0700-protected).
# Safe to source from scripts running with set -euo pipefail.
# A copy of this function is embedded in generate-site-env.sh (_detect_epas_instances)
# in the build repo. Keep the two copies in sync when changing either.
list_epas_instances() {
    local pid args data ver port owner mgr unit line
    local re_d='(^|[[:space:]])-D[[:space:]]*([^[:space:]]+)'
    local re_p='(^|[[:space:]])-p[[:space:]]*([0-9]+)'
    local -A seen=()

    # Pass 1: postmaster processes (covers systemd- and pg_ctl-started clusters)
    # Anchored: the program itself (argv[0]) must be the postmaster binary, so shells,
    # sudo or pg_ctl wrappers that merely mention it in their arguments don't match
    for pid in $(pgrep -f '^[^ ]*/bin/(edb-postmaster|edb-postgres|postmaster|postgres)( |$)' 2>/dev/null); do
        args=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || continue
        [[ $args =~ $re_d ]] || continue
        data=${BASH_REMATCH[2]}
        [[ -n ${seen[$data]:-} ]] && continue
        seen[$data]=1

        # Version: from the binary path (.../asNN/bin/...), else PG_VERSION
        if [[ ${args%% *} =~ /as([0-9]+)/bin/ ]]; then ver=${BASH_REMATCH[1]}
        else ver=$(cat "$data/PG_VERSION" 2>/dev/null || true); fi

        # Port: postmaster.pid (root/owner), else a -p on the command line
        port=$(sed -n 4p "$data/postmaster.pid" 2>/dev/null || true)
        if [[ -z $port && $args =~ $re_p ]]; then port=${BASH_REMATCH[2]}; fi

        owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
        # The cgroup tells us whether systemd started it (world-readable)
        unit=$(grep -oE '[^/]+\.service' "/proc/$pid/cgroup" 2>/dev/null | head -n1 || true)
        if [[ -n $unit && $unit != user@*.service && $unit != session-* ]]; then mgr="systemd:$unit"; else mgr="manual/pg_ctl"; fi

        echo "${ver:-?}|$data|${port:-?}|$pid|${owner:-?}|$mgr"
    done

    # Pass 2: active units whose process we could not see (e.g. /proc mounted with hidepid)
    if command -v systemctl &>/dev/null; then
        for unit in $(systemctl list-units 'edb-as-*' --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}'); do
            data=$(systemctl show -p Environment --value "$unit" 2>/dev/null | grep -oE '(^|[[:space:]])PGDATA=[^[:space:]]+' | tail -n1 || true)
            data=${data#*PGDATA=}
            [[ -z $data || -n ${seen[$data]:-} ]] && continue
            seen[$data]=1
            pid=$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)
            port=$(sed -n 4p "$data/postmaster.pid" 2>/dev/null || true)
            ver=${unit//[!0-9]/}
            echo "${ver:-?}|$data|${port:-?}|${pid:-?}|$(systemctl show -p User --value "$unit" 2>/dev/null || true)|systemd:$unit"
        done
    fi
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
            echo "(PORT '?' = no postmaster.pid in that data directory and no -p on the command line)" >&2
        else
            echo "(PORT '?' = postmaster.pid not readable as $(id -un); run as root or the DB owner)" >&2
        fi
    fi
    exit 0
fi
