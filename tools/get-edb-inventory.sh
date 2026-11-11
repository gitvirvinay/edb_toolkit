#!/usr/bin/env bash
# get-edb-inventory.sh — read-only report of the EDB / PostgreSQL software and instances on this host.
# Finds running servers from the process table (systemd-managed or not) and reads each one's facts from the
# server itself: data dir, port, binaries, version, role, TDE, systemd unit (all via lib/epas-detect.sh, the
# toolkit's shared detection). Also lists EFM agents/clusters, pgBackRest and installed EDB packages.
# Run as root for full detail; other users get what is readable (command line, cgroup) and 'unknown' for the rest.
# Every lookup falls back to empty/unknown: a missing tool or detail must never stop the report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/epas-detect.sh
source "${SCRIPT_DIR}/../lib/epas-detect.sh"

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

report() {
    echo "# EDB / PostgreSQL inventory of $(hostname -f 2>/dev/null || hostname) - $(date '+%F %T %Z')"
    [ "$(id -u)" -eq 0 ] || echo "# Not run as root: details of other users' servers may show as 'unknown'."
    echo
    echo "[HOST]"
    echo "HOSTNAME=\"$(hostname -s 2>/dev/null || hostname)\""
    echo "OS=\"$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)\""
    if have ip; then
        echo "PRIMARY_IP=\"$(epas_primary_ip)\""
        echo "IP_CIDRS=\"$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd' ' - || true)\""
    fi
    echo

    # --- running servers: every postmaster, even when this user can read only part of its details ---
    local n=0 pid
    while read -r pid; do
        [ -n "$pid" ] || continue
        n=$((n + 1))
        local user data bin port ver role tde unit comm
        user=$(epas_pid_owner "$pid")
        data=$(epas_pid_datadir "$pid")
        bin=$(epas_pid_bindir "$pid")
        comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
        ver=$(epas_version "$data" "$bin")
        port=""; role=unknown; tde=unknown
        if [ -n "$data" ]; then
            port=$(epas_port "$data" "$pid"); port=${port%%$'\t'*}
            role=$(epas_role "$data")
            tde=$(epas_tde "$data")
        fi
        unit=$(epas_pid_unit "$pid")
        echo "[INSTANCE_${n}]"
        echo "PID=\"${pid}\""
        echo "SERVICE_NAME=\"${unit%.service}\""
        echo "VERSION=\"${ver:-unknown}\""
        echo "PRODUCT=\"$([[ "$comm" == edb-* || "$bin" == */edb/* || -x ${bin:-/nonexistent}/edb-postgres ]] && echo EPAS || echo PostgreSQL)\""
        echo "SYSTEM_USER=\"${user:-unknown}\""
        echo "PORT=\"${port:-unknown}\""
        echo "DATA_DIR=\"${data:-unknown}\""
        echo "BIN_DIR=\"${bin:-unknown}\""
        echo "ROLE=\"${role}\""
        echo "TDE=\"${tde}\""
        echo
    done < <(epas_postmaster_pids)
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
