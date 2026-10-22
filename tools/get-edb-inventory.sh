#!/usr/bin/env bash
# get-edb-inventory.sh — read-only report of the EDB / PostgreSQL software and instances on this host.
# Finds running servers from the process table (systemd-managed or not) and reads each one's facts from the
# server itself: data dir (/proc/<pid>/cwd), port (postmaster.pid), binaries (/proc/<pid>/exe), version, role,
# TDE, systemd unit. Also lists EFM agents/clusters, pgBackRest and installed EDB packages.
# Run as root for full detail (other users' /proc entries are not readable).
# Every lookup falls back to empty/unknown: a missing tool or detail must never stop the report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

OUTPUT=""
usage() {
    cat <<USAGE
Usage: $0 [--output FILE]
Prints the inventory (INI-style sections) to the screen; --output also writes it to FILE. Changes nothing.
USAGE
    exit 0
}
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)  [ -n "${2:-}" ] || die "--output needs a file"; OUTPUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)         die "Unknown argument: $1 (see --help)" ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
SERVER_NAMES="postgres edb-postgres edb-postmaster postmaster"
is_server() { [[ " $SERVER_NAMES " == *" $1 "* ]]; }

report() {
    echo "# EDB / PostgreSQL inventory of $(hostname -f 2>/dev/null || hostname) - $(date '+%F %T %Z')"
    [ "$(id -u)" -eq 0 ] || echo "# Not run as root: details of other users' servers may show as 'unknown'."
    echo
    echo "[HOST]"
    echo "HOSTNAME=\"$(hostname -s 2>/dev/null || hostname)\""
    echo "OS=\"$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)\""
    if have ip; then
        echo "PRIMARY_IP=\"$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}' || true)\""
        echo "IP_CIDRS=\"$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd' ' - || true)\""
    fi
    echo

    # --- running servers: postmasters are server processes whose parent is not a server process ---
    local n=0 pid ppid comm pcomm
    while read -r pid ppid comm; do
        is_server "$comm" || continue
        pcomm=$(ps -o comm= -p "$ppid" 2>/dev/null || true)
        ! is_server "$pcomm" || continue
        n=$((n + 1))
        local user data exe bin port ver role tde unit
        user=$(ps -o user= -p "$pid" 2>/dev/null || echo unknown)
        data=$(readlink "/proc/${pid}/cwd" 2>/dev/null || true)
        exe=$(readlink "/proc/${pid}/exe" 2>/dev/null || true)
        bin=${exe:+$(dirname "$exe")}
        port=unknown; ver=unknown; role=unknown; tde=unknown
        if [ -n "$data" ] && [ -r "${data}/postmaster.pid" ]; then
            port=$(sed -n 4p "${data}/postmaster.pid" 2>/dev/null || echo unknown)
            ver=$(cat "${data}/PG_VERSION" 2>/dev/null || echo unknown)
            if [ -e "${data}/standby.signal" ]; then role=standby
            elif [ -e "${data}/recovery.signal" ]; then role=recovery
            else role=primary; fi
            [ -f "${data}/pg_encryption/key.bin" ] && tde=yes || tde=no
        fi
        unit=$(sed -n 's|.*/\([^/]*\.service\).*|\1|p' "/proc/${pid}/cgroup" 2>/dev/null | head -1 || true)
        [[ "$unit" != user@* && "$unit" != session-* ]] || unit=""
        echo "[INSTANCE_${n}]"
        echo "PID=\"${pid}\""
        echo "SERVICE_NAME=\"${unit%.service}\""
        echo "VERSION=\"${ver}\""
        echo "PRODUCT=\"$([[ "$comm" == edb-* || "$bin" == */edb/* ]] && echo EPAS || echo PostgreSQL)\""
        echo "SYSTEM_USER=\"${user}\""
        echo "PORT=\"${port}\""
        echo "DATA_DIR=\"${data:-unknown}\""
        echo "BIN_DIR=\"${bin:-unknown}\""
        echo "ROLE=\"${role}\""
        echo "TDE=\"${tde}\""
        echo
    done < <(ps -eo pid=,ppid=,comm= 2>/dev/null)
    [ "$n" -gt 0 ] || { echo "# No running PostgreSQL/EPAS server found."; echo; }

    # --- EFM ---
    local props found=false
    for props in /etc/edb/efm-*/*.properties; do
        [ -f "$props" ] || continue
        found=true
        local v c
        v=$(basename "$(dirname "$props")"); c=$(basename "$props" .properties)
        echo "[EFM_${c}]"
        echo "EFM_VERSION=\"${v#efm-}\""
        echo "CLUSTER=\"${c}\""
        echo "PROPERTIES=\"${props}\""
        echo "BIND_ADDRESS=\"$(get_property bind.address "$props" 2>/dev/null || true)\""
        echo "IS_WITNESS=\"$(get_property is.witness "$props" 2>/dev/null || true)\""
        echo "DB_PORT=\"$(get_property db.port "$props" 2>/dev/null || true)\""
        echo
    done
    if have systemctl; then
        local units
        units=$(systemctl list-units --all --type=service --no-legend 'edb-efm*' 'efm-*' 2>/dev/null | awk '{print ($1=="●"?$2:$1)"="($1=="●"?$5:$4)}' | paste -sd' ' - || true)
        [ -z "$units" ] || { echo "[EFM_SERVICES]"; echo "UNITS=\"${units}\""; echo; found=true; }
    fi
    [ "$found" = true ] || { echo "# No EFM configuration found."; echo; }

    # --- pgBackRest ---
    if have pgbackrest; then
        echo "[PGBACKREST]"
        echo "VERSION=\"$(pgbackrest version 2>/dev/null | awk '{print $2}' || true)\""
        echo "CONFIG=\"$(ls /etc/pgbackrest/pgbackrest.conf /etc/pgbackrest.conf 2>/dev/null | head -1 || true)\""
        echo
    fi

    # --- packages ---
    if have rpm; then
        echo "[PACKAGES]"
        rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 'edb-*' 'pgbackrest*' 'postgresql*' 2>/dev/null | sort | sed 's/^/PACKAGE=/' || true
        echo
    fi
}

if [ -n "$OUTPUT" ]; then
    report | tee "$OUTPUT"
    chmod 644 "$OUTPUT"
    log_info "Inventory written to ${OUTPUT}"
else
    report
fi
