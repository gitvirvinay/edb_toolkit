# shellcheck shell=bash
# =============================================================================
# epasenv - point the CURRENT shell at one EPAS cluster (like Oracle's oraenv)
#
# SOURCE it, never run it (a child process cannot change your shell):
#   . epasenv as17_rpt              registry name (/etc/edb/toolkit/epastab)
#   . epasenv 17                    version -> the registry entry as17
#   . epasenv /u001/data/as17_rpt   data directory (warns if a registry exists without it)
#   . epasenv                       menu (on a terminal)
# Options:
#   -q          quiet: no summary line (scripts)
#   -l          list the clusters it can switch to, change nothing
#   --default   pick without asking: the only running cluster, else as$EDB_DEFAULT_VERSION
#               (default 17), else the highest registered; used by the DBA .bashrc at login
#   -h          help
# Return codes: 0 switched | 1 cluster/binaries not found | 2 usage error
#
# Sets:   PGHOME PGDATA PGPORT PATH MANPATH EPAS_ACTIVE_VERSION EPAS_ACTIVE_SUBVERSION
#         EPAS_PORT_SOURCE EPAS_CLUSTER (registry name, or 'unregistered') EPAS_TAG
#         PGHOST = the cluster's socket directory, unset when that is /tmp or unknown
# Clears: PGSERVICE (with a notice) - it could override host/port/database.
# Keeps:  PGUSER, PGDATABASE (your deliberate choices).
#
# Installed as /usr/local/bin/epasenv -> /opt/edb_toolkit/tools/epasenv.sh (tools/install.sh).
# Uses lib/epas-detect.sh for all detection. Safe to source: changes no shell options,
# never exits your shell, leaves no helper functions behind.
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "epasenv needs bash" >&2
    return 2 2>/dev/null || exit 2
fi
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo "epasenv must be sourced to change your shell:  . epasenv <cluster|version|data dir>" >&2
    exit 2
fi

_epasenv_say()  { (( _EPASENV_QUIET )) || echo "$*"; }
_epasenv_err()  { echo "epasenv: $*" >&2; }

# Remove PATH-like entries: any <EDB_DEPLOYMENT_ROOT>/asNN/..., the previous PGHOME, and empty ones
_epasenv_strip() {   # _epasenv_strip VALUE OLD_HOME
    local -a parts; local p out=""
    IFS=: read -ra parts <<< "$1"
    for p in "${parts[@]}"; do
        [[ -z $p ]] && continue
        [[ $p == "${EDB_DEPLOYMENT_ROOT:-/usr/edb}"/as[0-9]* ]] && continue
        [[ -n ${2:-} && ( $p == "$2" || $p == "$2"/* ) ]] && continue
        out+="${out:+:}$p"
    done
    printf '%s' "$out"
}

# One record per choice: NAME|VERSION|DATA|PORT|SERVICE|TAG|SOURCE (registry or detected)
_epasenv_choices() {
    local r name ver data port svc tag
    local -A seen=()
    while IFS= read -r r; do
        IFS='|' read -r name ver data port svc tag <<< "$r"
        seen[$(readlink -m -- "$data")]=1
        echo "$name|$ver|$data|$port|$svc|$tag|registry"
    done < <(epas_registry_entries)
    # running clusters that are not registered
    while IFS='|' read -r ver data port _ _ mgr _; do
        [[ -n $data && -z ${seen[$(readlink -m -- "$data")]:-} ]] || continue
        seen[$(readlink -m -- "$data")]=1
        echo "unregistered|$ver|$data|$port|${mgr#systemd:}||detected"
    done < <(epas_instances)
    return 0
}

_epasenv_state() {   # running (systemd|pg_ctl) | stopped | unknown | missing
    local m
    [[ -d $1 ]] || { echo "missing"; return 0; }
    m=$(epas_manager "$1")
    case $m in
        systemd:*) echo "running (systemd)" ;;
        pg_ctl)    echo "running (pg_ctl)" ;;
        *)         echo "$m" ;;
    esac
}

_epasenv_list() {
    local name ver data port svc tag src i=0
    while IFS='|' read -r name ver data port svc tag src; do
        i=$((i + 1))
        printf '  %2d) %-14s %-4s %-6s %-5s %-18s %s\n' "$i" "$name" "${ver:-?}" "${port:-?}" "${tag:--}" "$(_epasenv_state "$data")" "$data"
    done < <(_epasenv_choices)
    (( i > 0 )) || echo "  (no clusters: none registered in $(epas_registry_file) and none running)"
    return 0
}

# Resolve the argument to a record NAME|VERSION|DATA|PORT|SERVICE|TAG|SOURCE
_epasenv_resolve() {
    local arg=$1 r want data ver v
    if [[ $arg == /* ]]; then                                   # data directory
        want=$(readlink -m -- "$arg")
        while IFS= read -r r; do
            IFS='|' read -r _ _ data _ <<< "$r"
            if [[ $(readlink -m -- "$data") == "$want" ]]; then echo "$r"; return 0; fi
        done < <(_epasenv_choices)
        if [[ -d $arg ]]; then                                  # not registered, not running
            echo "unregistered|$(epas_version "$arg")|${arg%/}||-||path"; return 0
        fi
        return 1
    fi
    [[ $arg =~ ^[0-9]+$ ]] && arg="as$arg"                      # version -> as<ver>
    r=$(epas_registry_get "$arg")
    if [[ -n $r ]]; then echo "$r|registry"; return 0; fi
    # Not registered. Only acceptable when there is no registry entry at all for it:
    # a running cluster of that version (if exactly one), else the standard data path.
    if [[ $arg =~ $EPAS_NAME_RE ]]; then
        v=${BASH_REMATCH[1]}
        local -a hits=()
        while IFS='|' read -r ver data _; do
            [[ $ver == "$v" && -n $data && $(basename "$data") == "$arg" ]] && hits+=("$data")
        done < <(epas_instances)
        if (( ${#hits[@]} == 0 )) && [[ $arg == "as$v" ]]; then
            while IFS='|' read -r ver data _; do
                [[ $ver == "$v" && -n $data ]] && hits+=("$data")
            done < <(epas_instances)
        fi
        if (( ${#hits[@]} == 1 )); then echo "unregistered|$v|${hits[0]}||-||detected"; return 0; fi
        if (( ${#hits[@]} > 1 )); then
            _epasenv_err "several running EPAS $v clusters and none registered as $arg - give the data directory, or register them (tools/epastab.sh import)"
            return 1
        fi
        for data in "${EDB_DATA_ROOT:-/u001/data}/$arg" "/var/lib/edb/as$v/data"; do
            if [[ -d $data ]]; then echo "unregistered|$v|$data||-||path"; return 0; fi
        done
    fi
    return 1
}

# --default: the only running cluster, else as$EDB_DEFAULT_VERSION, else the highest registered
_epasenv_default() {
    local -a running=() reg=()
    local name ver data port svc tag src r
    while IFS='|' read -r name ver data port svc tag src; do
        [[ $src == registry ]] && reg+=("$name|$ver|$data|$port|$svc|$tag|$src")
        case $(epas_manager "$data") in systemd:*|pg_ctl) running+=("$name|$ver|$data|$port|$svc|$tag|$src") ;; esac
    done < <(_epasenv_choices)
    if (( ${#running[@]} == 1 )); then echo "${running[0]}"; return 0; fi
    r=$(epas_registry_get "as${EDB_DEFAULT_VERSION:-17}")
    if [[ -n $r ]]; then echo "$r|registry"; return 0; fi
    if (( ${#reg[@]} > 0 )); then printf '%s\n' "${reg[@]}" | sort -t'|' -k2,2n | tail -n1; return 0; fi
    # no registry: fall back to the version rule
    _epasenv_resolve "${EDB_DEFAULT_VERSION:-17}"
}

_epasenv_main() {
    local arg="" mode=switch rec name ver data regport svc tag src
    local home pid bin port psrc sock old_home sub lp
    _EPASENV_QUIET=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            -q) _EPASENV_QUIET=1 ;;
            -l) mode=list ;;
            --default) mode=default ;;
            -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            -*) _epasenv_err "unknown option $1 (see: . epasenv -h)"; return 2 ;;
            *)  [[ -z $arg ]] || { _epasenv_err "only one cluster at a time"; return 2; }; arg=$1 ;;
        esac
        shift
    done

    # Shared detection library: next to this file (repo or /opt/edb_toolkit), else EDB_TOOLKIT_HOME
    if ! declare -F epas_registry_entries >/dev/null; then
        local here lib
        here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
        for lib in "$here/../lib/epas-detect.sh" "${EDB_TOOLKIT_HOME:-/opt/edb_toolkit}/lib/epas-detect.sh"; do
            if [[ -r $lib ]] && source "$lib" 2>/dev/null; then break; fi
        done
        declare -F epas_registry_entries >/dev/null || { _epasenv_err "lib/epas-detect.sh not found (install the toolkit: sudo tools/install.sh)"; return 1; }
    fi
    local regfile; regfile=$(epas_registry_file)

    if [[ $mode == list ]]; then
        echo "Clusters (registry: $regfile$([[ -r $regfile ]] || echo ' - not found')):"
        _epasenv_list; return 0
    fi

    # Which cluster?
    if [[ $mode == default ]]; then
        rec=$(_epasenv_default) || rec=""
        [[ -n $rec ]] || { _epasenv_err "no default cluster found"; return 1; }
    elif [[ -z $arg ]]; then
        if [[ ! -t 0 ]]; then _epasenv_err "which cluster? usage: . epasenv <name|version|data dir>  (-l lists them)"; return 2; fi
        local -a menu=(); local n
        mapfile -t menu < <(_epasenv_choices)
        (( ${#menu[@]} > 0 )) || { _epasenv_err "no clusters registered in $regfile and none running"; return 1; }
        echo "Clusters:"; _epasenv_list
        read -rp "Switch to [1-${#menu[@]}, Enter = cancel]: " n || return 2
        [[ -n $n ]] || return 2
        [[ $n =~ ^[0-9]+$ ]] && (( 10#$n >= 1 && 10#$n <= ${#menu[@]} )) || { _epasenv_err "invalid choice '$n'"; return 2; }
        rec=${menu[10#$n - 1]}
    else
        rec=$(_epasenv_resolve "$arg") || rec=""
        if [[ -z $rec ]]; then
            _epasenv_err "'$arg' is not a registered cluster, a version with a known cluster, or a data directory (see: . epasenv -l)"
            return 1
        fi
    fi
    IFS='|' read -r name ver data regport svc tag src <<< "$rec"

    # The cluster must exist
    [[ -d $data ]] || { _epasenv_err "$name: data directory $data does not exist (registry out of date? tools/epastab.sh check)"; return 1; }
    [[ -n $ver ]] || ver=$(epas_version "$data")
    [[ -n $ver ]] || { _epasenv_err "cannot tell the EPAS version of $data (run as its owner or root)"; return 1; }
    # Drift = a registry exists but does not know this cluster. No registry yet is not drift.
    if [[ $src != registry && -r $regfile ]]; then
        _epasenv_err "note: $data is not in the registry ($regfile) - drift; register it: tools/epastab.sh add ..."
    fi

    # Binaries: the running server's own tree, else the standard package path
    pid=$(epas_running_pid "$data")
    bin=""; [[ -n $pid ]] && bin=$(epas_pid_bindir "$pid")
    if [[ -n $bin && -x $bin/psql ]]; then home=$(dirname "$bin"); else home="${EDB_DEPLOYMENT_ROOT:-/usr/edb}/as$ver"; fi
    [[ -x $home/bin/psql ]] || { _epasenv_err "EPAS $ver binaries not found at $home"; return 1; }

    # Port: what the server uses - live when running, else its config files (what it will
    # start with) - then the registry for users who cannot read the config. A difference
    # between the real port and the registry is drift and is reported.
    port="" psrc=""
    if [[ -n $pid ]]; then IFS=$'\t' read -r port psrc <<< "$(epas_port "$data" "$pid")"
    else IFS=$'\t' read -r port psrc <<< "$(epas_port "$data")"; fi
    if [[ -n $port && -n $regport && $port != "$regport" ]]; then
        if [[ -n $pid ]]; then _epasenv_err "warning: $name runs on port $port but the registry says $regport (tools/epastab.sh check)"
        else _epasenv_err "warning: $name is configured for port $port but the registry says $regport (tools/epastab.sh check)"; fi
    fi
    if [[ -z $port && -n $regport ]]; then port=$regport psrc="registry"; fi
    # Guesses last: the DBA .bashrc's EPAS_PORT_MAP if it defines one, then 5444
    if [[ -z $port ]] && declare -p EPAS_PORT_MAP >/dev/null 2>&1 && [[ -n ${EPAS_PORT_MAP[$ver]:-} ]]; then
        port=${EPAS_PORT_MAP[$ver]} psrc="port map - fallback, verify!"
    fi
    if [[ -z $port ]]; then port=5444 psrc="EPAS default - verify!"; fi

    # Socket directory -> PGHOST (unset for /tmp or unknown: libpq's default)
    sock=$(epas_conf_get "$data" unix_socket_directories)
    sock=${sock%%,*}; sock=${sock//[[:space:]]/}

    # --- change the shell (nothing above has touched it) ---
    old_home=${PGHOME:-}
    PATH=$(_epasenv_strip "$PATH" "$old_home")
    MANPATH=$(_epasenv_strip "${MANPATH:-}" "$old_home")
    export PATH="$home/bin${PATH:+:$PATH}"
    export MANPATH="$home/share/man:${MANPATH}${MANPATH:+:}"
    if [[ -n ${LD_LIBRARY_PATH:-} ]]; then
        LD_LIBRARY_PATH=$(_epasenv_strip "$LD_LIBRARY_PATH" "$old_home")
        if [[ -n $LD_LIBRARY_PATH ]]; then export LD_LIBRARY_PATH; else unset LD_LIBRARY_PATH; fi
    fi
    if [[ ${EDB_SET_LD_LIBRARY_PATH:-no} == yes ]]; then export LD_LIBRARY_PATH="$home/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; fi

    sub=$("$home/bin/psql" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)
    export PGHOME="$home" PGDATA="$data" PGPORT="$port" EPAS_PORT_SOURCE="$psrc"
    export EPAS_ACTIVE_VERSION="$ver" EPAS_ACTIVE_SUBVERSION="${sub:-unknown}"
    export EPAS_CLUSTER="$name" EPAS_TAG="$tag"
    if [[ -n $sock && $sock != /tmp && -d $sock ]]; then export PGHOST="$sock"; else unset PGHOST; fi
    if [[ -n ${PGSERVICE:-} ]]; then
        _epasenv_err "note: PGSERVICE=$PGSERVICE was set; cleared so psql connects to $name"
        unset PGSERVICE
    fi
    hash -r

    lp="${tag:+ [$tag]}"
    _epasenv_say "EPAS $ver ($EPAS_ACTIVE_SUBVERSION) - $name$lp - $data - port $port ($psrc) - $(_epasenv_state "$data")${PGHOST:+ - socket $PGHOST}"
    return 0
}

# Remove every helper (and itself) from the shell, passing the result code through
_epasenv_cleanup() {
    local rc=$?
    unset -f _epasenv_say _epasenv_err _epasenv_strip _epasenv_choices _epasenv_state _epasenv_list \
             _epasenv_resolve _epasenv_default _epasenv_main _epasenv_cleanup
    unset _EPASENV_QUIET
    return "$rc"
}
_epasenv_main "$@"
_epasenv_cleanup
