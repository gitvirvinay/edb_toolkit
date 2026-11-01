# shellcheck shell=bash
# =============================================================================
# lib/epas-detect.sh - read-only detection of EPAS / PostgreSQL clusters
#
# ONE implementation of "which clusters are on this host and what are their
# details", shared by every edb_toolkit tool, the DBA .bashrc and epasenv.
#
# Load it, never run it:
#   source /opt/edb_toolkit/lib/epas-detect.sh            # shells, .bashrc, epasenv
#   source "${SCRIPT_DIR}/../lib/epas-detect.sh"           # scripts in the repo
#
# Rules this file keeps, so it is safe everywhere:
#   * Standalone: loads nothing else. (lib/common.sh is for scripts only: it
#     loads logger.sh, which turns on 'set -euo pipefail' and creates log dirs.)
#   * Safe in an interactive shell: changes no shell options, never exits,
#     prints nothing when loaded.
#   * Safe in strict scripts ('set -euo pipefail'): every function works there.
#   * Read-only: it never starts, stops or writes anything.
#   * Names: public functions epas_*, internal helpers _epas_*, constants EPAS_*.
#
# Contract (what callers can rely on):
#   * Query functions print a value - possibly empty when unknown - and return 0.
#   * Test functions (epas_is_*, epas_unit_loaded, epas_unit_active) print
#     nothing and return 0 (yes) or 1 (no).
#   * Records are one per line, fields separated by '|'. Unknown fields are empty.
#
# Detection method (decision 2026-10-31): a postmaster is a server process whose
# parent is not a server process. Its data directory is /proc/<pid>/cwd and its
# binaries /proc/<pid>/exe (readable by the owner and root); other users fall
# back to the command line (-D, program path) and the systemd unit.
#
# Public functions (details above each one):
#   epas_postmaster_pids                     PIDs of running postmasters
#   epas_instances                           running clusters, one record each
#   epas_pid_datadir / _bindir / _unit / _owner PID
#   epas_live_pid DIR | epas_running_pid DIR [VER]
#   epas_manager DIR                         systemd:<unit> | pg_ctl | stopped | unknown
#   epas_version DIR [BINDIR]                major version
#   epas_port DIR [PID]                      "PORT<TAB>SOURCE"
#   epas_conf_get DIR PARAM                  effective value from the config files
#   epas_role DIR | epas_tde DIR
#   epas_installed_versions [ROOT]           installed asNN trees under ROOT (/usr/edb)
#   epas_unit_loaded / _active / _pgdata UNIT
#   epas_primary_ip | epas_subnet [IP]
#   epas_registry_file | epas_registry_entries [FILE] | epas_registry_get NAME [FILE]
#   epas_is_valid_name NAME | epas_is_valid_tag TAG | epas_is_valid_port PORT
# =============================================================================

# Bash only (arrays, [[ ]], regex). Refuse quietly in other shells.
[ -n "${BASH_VERSION:-}" ] || { echo "epas-detect.sh needs bash" >&2; return 1 2>/dev/null || exit 1; }

# Run directly by mistake? Explain instead of doing nothing silently.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo "lib/epas-detect.sh is a library: load it with 'source', e.g. tools/list_epas_instances.sh shows clusters." >&2
    exit 2
fi

EPAS_DETECT_VERSION="1.0.0"
EPAS_SERVER_NAMES="postgres edb-postgres edb-postmaster postmaster"
EPAS_NAME_RE='^as([0-9]{2})(_[a-z0-9]+)?$'      # registry names: as17, as17_rpt
EPAS_TAGS="DEV SIT PAT PROD"

# -----------------------------------------------------------------------------
# Small internal helpers
# -----------------------------------------------------------------------------
_epas_is_server_name() { [[ " $EPAS_SERVER_NAMES " == *" ${1:-} "* ]]; }

# Command line of PID with arguments separated by spaces ('' if not readable)
_epas_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true; }

# -----------------------------------------------------------------------------
# Finding postmasters
# -----------------------------------------------------------------------------

# epas_postmaster_pids -> one PID per line.
# A postmaster is a server process whose parent is not one; its own children
# (checkpointer, walwriter, backends) have the postmaster as parent and are skipped.
epas_postmaster_pids() {
    local pid ppid comm pcomm snap
    local -A name_of=()
    snap=$(ps -eo pid=,ppid=,comm= 2>/dev/null || true)     # one snapshot for both passes
    while read -r pid ppid comm; do
        [[ -n $pid ]] && name_of[$pid]=$comm
    done <<< "$snap"
    while read -r pid ppid comm; do
        _epas_is_server_name "$comm" || continue
        pcomm=${name_of[$ppid]:-}
        _epas_is_server_name "$pcomm" && continue
        echo "$pid"
    done <<< "$snap"
    return 0
}

# epas_pid_datadir PID -> data directory of a postmaster
#   /proc/PID/cwd (owner/root) -> -D on the command line -> PGDATA of its systemd unit
epas_pid_datadir() {
    local pid=$1 d args unit
    local re='(^|[[:space:]])-D[[:space:]]*([^[:space:]]+)'
    d=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
    if [[ -n $d && $d != / ]]; then echo "$d"; return 0; fi
    args=$(_epas_cmdline "$pid")
    if [[ $args =~ $re ]]; then echo "${BASH_REMATCH[2]}"; return 0; fi
    unit=$(epas_pid_unit "$pid")
    if [[ -n $unit ]]; then
        d=$(epas_unit_pgdata "$unit")
        if [[ -n $d ]]; then echo "$d"; return 0; fi
    fi
    return 0
}

# epas_pid_bindir PID -> directory of the server binary
#   /proc/PID/exe (owner/root; symlinks resolved) -> program path on the command line
epas_pid_bindir() {
    local pid=$1 exe args
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    exe=${exe% (deleted)}                      # binary replaced by a package update
    if [[ -z $exe ]]; then
        args=$(_epas_cmdline "$pid")
        exe=${args%% *}
    fi
    if [[ $exe == /* ]]; then dirname "$exe"; fi
    return 0
}

# epas_pid_unit PID -> systemd unit that started it (e.g. edb-as-17.service), '' if none
# Read from /proc/PID/cgroup, which every user can read.
epas_pid_unit() {
    local u
    u=$(grep -oE '[^/]+\.service' "/proc/$1/cgroup" 2>/dev/null | head -n1 || true)
    case $u in
        ""|user@*|session-*) ;;              # a login session, not a service
        *) echo "$u" ;;
    esac
    return 0
}

# epas_pid_owner PID -> OS user running the process
epas_pid_owner() {
    ps -o user= -p "$1" 2>/dev/null | tr -d '[:space:]' || true
    return 0
}

# epas_live_pid DIR -> postmaster PID from DIR/postmaster.pid if that process is alive
# (needs read access to DIR: owner/root)
epas_live_pid() {
    local pid
    [[ -r ${1:-}/postmaster.pid ]] || return 0
    pid=$(head -n1 "$1/postmaster.pid" 2>/dev/null || true)
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; fi
    return 0
}

# epas_running_pid DIR -> postmaster PID serving DIR, for any user.
# postmaster.pid first (owner/root), then every postmaster's data directory.
epas_running_pid() {
    local dir=$1 pid want
    pid=$(epas_live_pid "$dir")
    if [[ -n $pid ]]; then echo "$pid"; return 0; fi
    want=$(readlink -m -- "$dir")
    while read -r pid; do
        [[ -n $pid ]] || continue
        if [[ $(readlink -m -- "$(epas_pid_datadir "$pid")") == "$want" ]]; then echo "$pid"; return 0; fi
    done < <(epas_postmaster_pids)
    return 0
}

# _epas_unresolved_postmaster -> true if some running postmaster's data directory
# cannot be determined as this user (no read access to /proc/<pid>/cwd, no -D, no unit).
_epas_unresolved_postmaster() {
    local pid
    while read -r pid; do
        [[ -n $pid && -z $(epas_pid_datadir "$pid") ]] && return 0
    done < <(epas_postmaster_pids)
    return 1
}

# epas_manager DIR -> who controls the cluster now:
#   systemd:<unit> | pg_ctl | stopped | unknown
# A postmaster started by systemd lives in its unit's cgroup; one started by pg_ctl does not.
# 'unknown' (never a guessed 'stopped'): DIR is not readable as this user AND some running
# postmaster's data directory cannot be seen - it might be this cluster.
epas_manager() {
    local dir=$1 pid unit
    pid=$(epas_running_pid "$dir")
    if [[ -z $pid ]]; then
        if [[ -r $dir && -x $dir ]] || ! _epas_unresolved_postmaster; then echo stopped; else echo unknown; fi
        return 0
    fi
    unit=$(epas_pid_unit "$pid")
    if [[ -n $unit ]]; then echo "systemd:$unit"; else echo pg_ctl; fi
    return 0
}

# -----------------------------------------------------------------------------
# Facts about a data directory
# -----------------------------------------------------------------------------

# epas_version DIR [BINDIR] -> major version
#   DIR/PG_VERSION (owner/root) -> .../asNN/... in BINDIR -> .../pgsql-NN/ or .../postgresql/NN/
epas_version() {
    local v="" b=${2:-}
    if [[ -r ${1:-}/PG_VERSION ]]; then v=$(tr -d '[:space:]' < "$1/PG_VERSION" 2>/dev/null || true); fi
    if [[ -z $v && $b =~ /as([0-9]+)(/|$) ]]; then v=${BASH_REMATCH[1]}; fi
    if [[ -z $v && $b =~ /(pgsql-|postgresql/)([0-9]+)(/|$) ]]; then v=${BASH_REMATCH[2]}; fi
    echo "$v"
    return 0
}

# epas_role DIR -> primary | standby | recovery | unknown (not readable)
epas_role() {
    [[ -r ${1:-} && -x ${1:-} ]] || { echo unknown; return 0; }
    if   [[ -e $1/standby.signal ]];  then echo standby
    elif [[ -e $1/recovery.signal ]]; then echo recovery
    else echo primary; fi
    return 0
}

# epas_tde DIR -> yes | no | unknown (EPAS Transparent Data Encryption key present?)
epas_tde() {
    [[ -r ${1:-} && -x ${1:-} ]] || { echo unknown; return 0; }
    if [[ -f $1/pg_encryption/key.bin ]]; then echo yes; else echo no; fi
    return 0
}

# --- configuration files ------------------------------------------------------

# _epas_conf_values FILE PARAM [DEPTH] -> every value PARAM gets in FILE, in order.
# Follows include, include_if_exists and include_dir (files *.conf, C sort order)
# exactly where they appear, as the server does. Parameter names are case-insensitive.
_epas_conf_values() {
    local f=$1 p=${2,,} depth=${3:-0} line key val dir inc g
    local re="^[[:space:]]*([A-Za-z_][A-Za-z0-9_.]*)[[:space:]]*=?[[:space:]]*('([^']|'')*'|[^[:space:]#]+)"
    [[ -r $f ]] && (( depth < 10 )) || return 0
    dir=$(dirname "$f")
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ $re ]] || continue
        key=${BASH_REMATCH[1],,}
        val=${BASH_REMATCH[2]}
        if [[ $val == \'*\' ]]; then val=${val:1:${#val}-2}; val=${val//\'\'/\'}; fi
        case $key in
            include|include_if_exists)
                [[ $val == /* ]] || val="$dir/$val"
                _epas_conf_values "$val" "$p" $((depth + 1)) ;;
            include_dir)
                [[ $val == /* ]] || val="$dir/$val"
                while IFS= read -r inc; do
                    [[ -n $inc ]] && _epas_conf_values "$inc" "$p" $((depth + 1))
                done < <(for g in "$val"/*.conf; do [[ -f $g && ${g##*/} != .* ]] && echo "$g"; done | LC_ALL=C sort)
                ;;
            "$p") printf '%s\n' "$val" ;;
        esac
    done < "$f"
    return 0
}

# epas_conf_get DIR PARAM -> effective value from DIR/postgresql.conf (with its includes)
# and DIR/postgresql.auto.conf (read last, so it wins). '' if unset or not readable.
epas_conf_get() {
    { _epas_conf_values "$1/postgresql.conf" "$2"; _epas_conf_values "$1/postgresql.auto.conf" "$2"; } | tail -n1 || true
    return 0
}

# epas_port DIR [PID] -> "PORT<TAB>SOURCE", or nothing if unknown. Most reliable first:
#   postmaster.pid (running; owner/root) -> -p on the postmaster command line (anyone)
#   -> config files (owner/root) -> the only server socket in /tmp, if this is the
#   only postmaster on the host (anyone). Guesses (port maps, 5444) are the caller's job.
epas_port() {
    local dir=$1 pid=${2:-} p args socks n
    local re='(^|[[:space:]])-p[[:space:]]*([0-9]+)'
    if [[ -n $(epas_live_pid "$dir") ]]; then
        p=$(sed -n 4p "$dir/postmaster.pid" 2>/dev/null || true)
        if [[ $p =~ ^[0-9]+$ ]]; then printf '%s\tpostmaster.pid\n' "$p"; return 0; fi
    fi
    [[ -n $pid ]] || pid=$(epas_running_pid "$dir")
    if [[ -n $pid ]]; then
        args=$(_epas_cmdline "$pid")
        if [[ $args =~ $re ]]; then printf '%s\tpostmaster -p option\n' "${BASH_REMATCH[2]}"; return 0; fi
    fi
    p=$(epas_conf_get "$dir" port)
    if [[ $p =~ ^[0-9]+$ ]]; then printf '%s\tconfig files\n' "$p"; return 0; fi
    if [[ -n $pid ]]; then
        n=$(epas_postmaster_pids | grep -c . || true)
        socks=$(ls -1 /tmp/.s.PGSQL.* 2>/dev/null | grep -v '\.lock$' || true)
        if [[ $n == 1 && -n $socks && $(grep -c . <<< "$socks") == 1 ]]; then
            printf '%s\tsocket %s\n' "${socks##*.}" "$socks"; return 0
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# All running clusters
# -----------------------------------------------------------------------------

# epas_instances -> one record per running cluster:
#   VERSION|PGDATA|PORT|PID|OWNER|MANAGED_BY|BINDIR|ROLE|TDE
# MANAGED_BY is systemd:<unit> or pg_ctl. Empty field = could not be read as this user.
# Clusters hidden from the process table (/proc mounted with hidepid) are added from
# running edb-as-* systemd units.
epas_instances() {
    local pid data bin ver port owner unit mgr u
    local -A seen=()
    while read -r pid; do
        [[ -n $pid ]] || continue
        data=$(epas_pid_datadir "$pid")
        [[ -n $data && -z ${seen[$data]:-} ]] || continue
        seen[$data]=1
        bin=$(epas_pid_bindir "$pid")
        ver=$(epas_version "$data" "$bin")
        port=$(epas_port "$data" "$pid"); port=${port%%$'\t'*}
        owner=$(epas_pid_owner "$pid")
        unit=$(epas_pid_unit "$pid")
        if [[ -n $unit ]]; then mgr="systemd:$unit"; else mgr="pg_ctl"; fi
        echo "$ver|$data|$port|$pid|$owner|$mgr|$bin|$(epas_role "$data")|$(epas_tde "$data")"
    done < <(epas_postmaster_pids)

    command -v systemctl >/dev/null 2>&1 || return 0
    while read -r u; do
        [[ -n $u ]] || continue
        data=$(epas_unit_pgdata "$u")
        [[ -n $data && -z ${seen[$data]:-} ]] || continue
        seen[$data]=1
        pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null || true)
        [[ $pid == 0 ]] && pid=""
        port=$(epas_port "$data" "$pid"); port=${port%%$'\t'*}
        ver=$(epas_version "$data"); [[ -n $ver ]] || ver=$(grep -oE '[0-9]+' <<< "$u" | head -n1 || true)
        owner=$(systemctl show -p User --value "$u" 2>/dev/null || true)
        echo "$ver|$data|$port|$pid|$owner|systemd:$u||$(epas_role "$data")|$(epas_tde "$data")"
    done < <(systemctl list-units 'edb-as-*' --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
    return 0
}

# epas_installed_versions [ROOT] -> major versions with a server binary under ROOT/asNN/bin
# (ROOT defaults to /usr/edb; ascending)
epas_installed_versions() {
    local root=${1:-/usr/edb} d
    for d in "$root"/as[0-9]*; do
        [[ ${d##*/as} =~ ^[0-9]+$ ]] || continue
        if [[ -x $d/bin/edb-postgres || -x $d/bin/postgres || -x $d/bin/psql ]]; then echo "${d##*/as}"; fi
    done | sort -n || true
    return 0
}

# -----------------------------------------------------------------------------
# systemd
# -----------------------------------------------------------------------------
epas_unit_loaded() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ $(systemctl show -p LoadState --value "${1:-}" 2>/dev/null || true) == loaded ]]
}
epas_unit_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "${1:-}" 2>/dev/null
}
# epas_unit_pgdata UNIT -> PGDATA from the unit's effective environment (file + all drop-ins)
epas_unit_pgdata() {
    local d
    command -v systemctl >/dev/null 2>&1 || return 0
    d=$(systemctl show -p Environment --value "$1" 2>/dev/null | grep -oE '(^|[[:space:]])"?PGDATA=[^[:space:]"]+' | tail -n1 || true)
    d=${d#*PGDATA=}
    [[ -n $d ]] && echo "$d"
    return 0
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
# epas_primary_ip -> source address of the default route
epas_primary_ip() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true
    return 0
}
# epas_subnet [IP] -> network of IP (default: primary IP), e.g. 10.0.1.0/24 - real prefix, not assumed /24
epas_subnet() {
    local a=${1:-}
    [[ -n $a ]] || a=$(epas_primary_ip)
    [[ -n $a ]] || return 0
    ip -o -4 route show proto kernel scope link src "$a" 2>/dev/null | awk '{print $1; exit}' || true
    return 0
}

# -----------------------------------------------------------------------------
# Cluster registry (/etc/edb/toolkit/epastab) - reading only; tools/epastab.sh writes it
# -----------------------------------------------------------------------------
epas_registry_file() { echo "${EPASTAB:-/etc/edb/toolkit/epastab}"; }

# epas_registry_entries [FILE] -> NAME|VERSION|DATA|PORT|SERVICE|TAG for each well-formed line
epas_registry_entries() {
    local f=${1:-$(epas_registry_file)} line name ver data port svc tag extra
    [[ -r $f ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
        IFS=: read -r name ver data port svc tag extra <<< "$line"
        [[ -n $name && -n $ver && -n $data && -n $port && -n $svc && -n $tag && -z ${extra:-} ]] || continue
        echo "$name|$ver|$data|$port|$svc|$tag"
    done < "$f"
    return 0
}

# epas_registry_get NAME [FILE] -> that entry's record, or nothing
epas_registry_get() {
    local r
    while IFS= read -r r; do
        if [[ ${r%%|*} == "$1" ]]; then echo "$r"; return 0; fi
    done < <(epas_registry_entries "${2:-}")
    return 0
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
epas_is_valid_name() { [[ ${1:-} =~ $EPAS_NAME_RE && ${#1} -le 32 ]]; }
epas_is_valid_tag()  { [[ -n ${1:-} && " $EPAS_TAGS " == *" $1 "* ]]; }
epas_is_valid_port() { [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
