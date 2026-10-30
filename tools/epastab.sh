#!/usr/bin/env bash
# =============================================================================
# tools/epastab.sh - maintain the EPAS cluster registry /etc/edb/toolkit/epastab
#
# The registry is the DECLARED state of a host: which EPAS clusters SHOULD exist
# on it (like Oracle's /etc/oratab). Detection tools show the OBSERVED state;
# 'check' compares the two and reports drift.
#
# This script is the ONLY writer of the registry. Everything else (epasenv,
# the DBA .bashrc, get-edb-inventory.sh, monitoring) only reads it.
#
# Usage:
#   epastab.sh add    --name as17 --data /u001/data/as17 --port 5444 --tag PROD
#                     [--service edb-as-17 | --service -] [--version 17]
#   epastab.sh remove --name as15 [--yes]
#   epastab.sh list   [--raw]
#   epastab.sh check
#   epastab.sh import --tag PROD [--dry-run] [--yes]
#   epastab.sh init   [--env conf/site.env | --owner USER[:GROUP]] [--yes]    (root, once per host)
#
# File format (one line per cluster, no spaces, '#' = comment):
#   name:version:data_directory:port:service:tag
#   as17:17:/u001/data/as17:5444:edb-as-17:PROD
#
#   name     as<major>[_suffix]  e.g. as17, as17_rpt (lowercase, max 32 chars)
#   service  systemd unit that runs the cluster, or '-' when managed with pg_ctl
#   tag      DEV | SIT | PAT | PROD   (a DR copy of production is PROD)
#
# Not stored on purpose: primary/standby role (changes on failover - read it live),
# binary path, OS owner and minor version (always derivable).
#
# Exit codes: 0 ok | 1 error | 2 'check' found drift
#
# Ownership (no root needed day to day): the registry lives in /etc/edb/toolkit/,
# a directory owned by the database OS user (SYSTEM_USER in conf/site.env). Root
# creates it once with 'init'; after that the owner maintains the registry, like
# the oracle user maintains /etc/oratab. Whoever owns the directory may write;
# no user name is hard-coded. Root can also write and keeps the owner unchanged.
# The directory, not /etc/edb itself, is delegated: /etc/edb also holds EDB
# package files (e.g. EFM) that the database user must not be able to replace.
# Registry path: /etc/edb/toolkit/epastab, or $EPASTAB to point at another file (tests).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# Running-instance detection (VERSION|PGDATA|PORT|PID|OWNER|MANAGED_BY)
# shellcheck source=list_epas_instances.sh
source "${SCRIPT_DIR}/list_epas_instances.sh"

EPASTAB="${EPASTAB:-/etc/edb/toolkit/epastab}"
TAGS="DEV SIT PAT PROD"
NAME_RE='^as([0-9]{2})(_[a-z0-9]+)?$'

usage() {
    sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------
say()   { printf '%s\n' "$*"; }
# optval OPTION "$@" -> stop with a clear message when an option has no value
optval() { [[ $# -ge 2 && -n ${2:-} && ${2:-} != --* ]] || die "$1 needs a value (see --help)"; }
canon() { readlink -m -- "$1"; }          # absolute path, symlinks resolved

# Port the cluster is CONFIGURED with: postgresql.conf, conf.d/*.conf (sorted),
# postgresql.auto.conf - last setting wins, as the server reads them. '' if none.
conf_port() {
    local d=$1 f q p=""
    local -a files=("$d/postgresql.conf")
    if [[ -d $d/conf.d ]]; then
        while IFS= read -r f; do files+=("$f"); done < <(ls -1 "$d"/conf.d/*.conf 2>/dev/null | sort || true)
    fi
    files+=("$d/postgresql.auto.conf")
    for f in "${files[@]}"; do
        [[ -r $f ]] || continue
        q=$(sed -nE "s/^[[:space:]]*port[[:space:]]*=[[:space:]]*'?([0-9]+).*/\1/p" "$f" | tail -n1 || true)
        if [[ -n $q ]]; then p=$q; fi
    done
    printf '%s' "$p"
}

# Live port of a running cluster from postmaster.pid (line 4); '' if stopped/unreadable
live_port() {
    local d=$1 pid
    [[ -r $d/postmaster.pid ]] || return 0
    pid=$(head -n1 "$d/postmaster.pid" 2>/dev/null || true)
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        sed -n 4p "$d/postmaster.pid" 2>/dev/null || true
    fi
}

have_systemd() { command -v systemctl >/dev/null 2>&1; }
unit_loaded()  { have_systemd && [[ $(systemctl show -p LoadState --value "$1" 2>/dev/null || true) == loaded ]]; }
unit_pgdata() {
    local d
    d=$(systemctl show -p Environment --value "$1" 2>/dev/null | grep -oE '(^|[[:space:]])PGDATA=[^[:space:]]+' | tail -n1 || true)
    printf '%s' "${d#*PGDATA=}"
}

# Default service for a cluster: edb-as-<ver> if that unit exists AND runs this data dir
guess_service() {
    local ver=$1 data=$2 u="edb-as-$1"
    if unit_loaded "$u" && [[ $(canon "$(unit_pgdata "$u")") == "$(canon "$data")" ]]; then
        echo "$u"
    else
        echo "-"
    fi
}

# --------------------------------------------------------------------------
# Reading the registry
# --------------------------------------------------------------------------
E_NAME=() E_VER=() E_DATA=() E_PORT=() E_SVC=() E_TAG=()
BAD_LINES=()

read_registry() {
    local line n=0 name ver data port svc tag extra
    E_NAME=() E_VER=() E_DATA=() E_PORT=() E_SVC=() E_TAG=() BAD_LINES=()
    [[ -f $EPASTAB ]] || return 0
    [[ -r $EPASTAB ]] || die "Cannot read $EPASTAB as $(id -un)"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
        IFS=: read -r name ver data port svc tag extra <<< "$line"
        if [[ -z $name || -z $ver || -z $data || -z $port || -z $svc || -z $tag || -n ${extra:-} ]]; then
            BAD_LINES+=("line $n: $line")
            continue
        fi
        E_NAME+=("$name") E_VER+=("$ver") E_DATA+=("$data")
        E_PORT+=("$port") E_SVC+=("$svc") E_TAG+=("$tag")
    done < "$EPASTAB"
}

find_entry() {   # index of entry NAME, or nothing
    local i
    for i in "${!E_NAME[@]}"; do
        if [[ ${E_NAME[$i]} == "$1" ]]; then echo "$i"; return 0; fi
    done
    return 0
}

# --------------------------------------------------------------------------
# Writing the registry (single writer, validated, locked, atomic)
# --------------------------------------------------------------------------
reg_dir() { dirname "$EPASTAB"; }
dir_owner() { stat -c '%U' "$(reg_dir)" 2>/dev/null || echo "?"; }

# Who to ask for when access is missing: the registry directory's owner, or root
who_can_write() {
    local o; o=$(dir_owner)
    if [[ $o == "?" || $o == root ]]; then echo "root"; else echo "$o (owner of $(reg_dir)) or root"; fi
}

need_write_access() {
    local d; d=$(reg_dir)
    [[ -d $d ]] || die "Registry directory $d does not exist. One-time setup by root: sudo $0 init"
    [[ -w $d ]] || die "No write access to $d as $(id -un) - run as $(who_can_write)"
    if [[ -e ${EPASTAB}.lock && ! -w ${EPASTAB}.lock ]]; then
        die "${EPASTAB}.lock is owned by $(stat -c %U "${EPASTAB}.lock") - repair ownership once with: sudo $0 init"
    fi
    ((${#BAD_LINES[@]} == 0)) || die "$EPASTAB has malformed lines - fix or remove them first: ${BAD_LINES[*]}"
}

# Root keeps everything owned by the directory owner, so that user can still write later
give_to_dir_owner() {
    (( EUID == 0 )) || return 0
    local og; og=$(stat -c '%U:%G' "$(reg_dir)")
    chown "$og" "$@" 2>/dev/null || true
}

# Serialise writers: a second run waits up to 30 s instead of overwriting the first
take_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>> "${EPASTAB}.lock"
    give_to_dir_owner "${EPASTAB}.lock"
    flock -w 30 9 || die "Another epastab.sh is writing $EPASTAB (lock ${EPASTAB}.lock)"
}

write_registry() {
    local tmp i
    tmp=$(mktemp "$(reg_dir)/.epastab.XXXXXX")
    {
        echo "# $EPASTAB - EPAS cluster registry: clusters that SHOULD exist on this host."
        echo "# Managed by edb_toolkit tools/epastab.sh - do not edit by hand. Last change: $(date '+%F %T') by $(id -un)."
        echo "# Format: name:version:data_directory:port:service:tag   (service '-' = pg_ctl, tag DEV|SIT|PAT|PROD)"
        for i in "${!E_NAME[@]}"; do
            printf '%s:%s:%s:%s:%s:%s\n' "${E_NAME[$i]}" "${E_VER[$i]}" "${E_DATA[$i]}" \
                "${E_PORT[$i]}" "${E_SVC[$i]}" "${E_TAG[$i]}"
        done
    } > "$tmp"
    chmod 644 "$tmp"
    give_to_dir_owner "$tmp"
    if [[ -f $EPASTAB ]]; then cp -p "$EPASTAB" "${EPASTAB}.prev"; give_to_dir_owner "${EPASTAB}.prev"; fi
    mv -f "$tmp" "$EPASTAB"
}

# validate NAME VERSION DATA PORT SERVICE TAG [skip_index] -> dies with a clear reason
validate() {
    local name=$1 ver=$2 data=$3 port=$4 svc=$5 tag=$6 skip=${7:-} i pgv
    [[ $name =~ $NAME_RE ]] || die "Invalid name '$name': use as<major>[_suffix], e.g. as17 or as17_rpt (lowercase letters/digits)"
    (( ${#name} <= 32 )) || die "Name '$name' is longer than 32 characters"
    [[ ${BASH_REMATCH[1]} == "$ver" ]] || die "Name '$name' says version ${BASH_REMATCH[1]} but version is '$ver'"
    [[ $data == /* && $data =~ ^[A-Za-z0-9._/+-]+$ && $data != *..* ]] \
        || die "Invalid data directory '$data': absolute path, letters/digits and . _ - + / only"
    [[ -d $data ]] || die "Data directory not found: $data"
    if [[ -r $data/PG_VERSION ]]; then
        pgv=$(tr -d '[:space:]' < "$data/PG_VERSION")
        [[ $pgv == "$ver" ]] || die "$data/PG_VERSION is '$pgv', not version $ver"
    else
        [[ -e $data/PG_VERSION ]] || die "$data is not a cluster (no PG_VERSION) - run initdb first"
        die "Cannot read $data/PG_VERSION as $(id -un) - run as the cluster owner or root"
    fi
    [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || die "Invalid port '$port' (1-65535)"
    [[ $svc == "-" || $svc =~ ^[A-Za-z0-9@._-]+$ ]] || die "Invalid service '$svc' (systemd unit name, or -)"
    [[ " $TAGS " == *" $tag "* ]] || die "Invalid tag '$tag': one of $TAGS"
    for i in "${!E_NAME[@]}"; do
        [[ $i == "$skip" ]] && continue
        [[ ${E_NAME[$i]} != "$name" ]] || die "Name '$name' is already registered"
        [[ $(canon "${E_DATA[$i]}") != "$(canon "$data")" ]] || die "Data directory $data is already registered as '${E_NAME[$i]}'"
        [[ ${E_PORT[$i]} != "$port" ]] || die "Port $port is already used by '${E_NAME[$i]}'"
    done
    if [[ $svc != "-" ]] && have_systemd && ! unit_loaded "$svc"; then
        log_warn "Service '$svc' is not installed on this host (registering anyway)"
    fi
    return 0
}

# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------
cmd_add() {
    local name="" ver="" data="" port="" svc="" tag="" i
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)    optval "$@"; name=$2; shift 2 ;;
            --version) optval "$@"; ver=$2; shift 2 ;;
            --data)    optval "$@"; data=$2; shift 2 ;;
            --port)    optval "$@"; port=$2; shift 2 ;;
            --service) optval "$@"; svc=$2; shift 2 ;;
            --tag)     optval "$@"; tag=${2^^}; shift 2 ;;
            *) die "add: unknown option '$1' (see --help)" ;;
        esac
    done
    [[ -n $name && -n $data && -n $port && -n $tag ]] || die "add needs --name, --data, --port and --tag (see --help)"
    [[ $name =~ $NAME_RE ]] || die "Invalid name '$name': use as<major>[_suffix], e.g. as17 or as17_rpt"
    [[ -n $ver ]] || ver=${BASH_REMATCH[1]}
    data=${data%/}
    [[ -n $svc ]] || svc=$(guess_service "$ver" "$data")

    read_registry
    need_write_access
    take_lock
    read_registry                                  # re-read under the lock

    i=$(find_entry "$name")
    if [[ -n $i ]]; then
        if [[ ${E_VER[$i]}:${E_DATA[$i]}:${E_PORT[$i]}:${E_SVC[$i]}:${E_TAG[$i]} == "$ver:$data:$port:$svc:$tag" ]]; then
            log_info "'$name' is already registered with the same values - nothing to do"
            return 0
        fi
        die "'$name' is already registered with different values (${E_VER[$i]}:${E_DATA[$i]}:${E_PORT[$i]}:${E_SVC[$i]}:${E_TAG[$i]}). Remove it first if this is intended."
    fi

    validate "$name" "$ver" "$data" "$port" "$svc" "$tag"
    E_NAME+=("$name") E_VER+=("$ver") E_DATA+=("$data") E_PORT+=("$port") E_SVC+=("$svc") E_TAG+=("$tag")
    write_registry
    log_audit "epastab: registered $name:$ver:$data:$port:$svc:$tag in $EPASTAB"
}

cmd_remove() {
    local name="" i
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name) optval "$@"; name=$2; shift 2 ;;
            *) die "remove: unknown option '$1' (see --help)" ;;
        esac
    done
    [[ -n $name ]] || die "remove needs --name"
    read_registry
    need_write_access
    take_lock
    read_registry
    i=$(find_entry "$name")
    if [[ -z $i ]]; then
        log_info "'$name' is not registered - nothing to do"
        return 0
    fi
    confirm_or_exit "remove '$name' (${E_DATA[$i]}, port ${E_PORT[$i]}, ${E_TAG[$i]}) from $EPASTAB - the cluster itself is not touched"
    unset 'E_NAME[i]' 'E_VER[i]' 'E_DATA[i]' 'E_PORT[i]' 'E_SVC[i]' 'E_TAG[i]'
    E_NAME=("${E_NAME[@]}") E_VER=("${E_VER[@]}") E_DATA=("${E_DATA[@]}")
    E_PORT=("${E_PORT[@]}") E_SVC=("${E_SVC[@]}") E_TAG=("${E_TAG[@]}")
    write_registry
    log_audit "epastab: removed $name from $EPASTAB"
}

# STATE of a registered cluster: running | stopped | unknown (not readable)
entry_state() {
    local data=$1 line
    if [[ -n $(live_port "$data") ]]; then echo running; return; fi
    while IFS= read -r line; do
        IFS='|' read -r _ d _ <<< "$line"
        if [[ $(canon "$d") == "$(canon "$data")" ]]; then echo running; return; fi
    done < <(list_epas_instances)
    if [[ -r $data ]]; then echo stopped; else echo unknown; fi
}

cmd_list() {
    local raw=0 i
    while [[ $# -gt 0 ]]; do
        case $1 in
            --raw) raw=1; shift ;;
            *) die "list: unknown option '$1' (see --help)" ;;
        esac
    done
    if [[ ! -f $EPASTAB ]]; then
        say "No registry yet ($EPASTAB). Create it with: epastab.sh import --tag <TAG>  or  epastab.sh add ..."
        return 0
    fi
    if (( raw )); then grep -vE '^[[:space:]]*(#|$)' "$EPASTAB" || true; return 0; fi
    read_registry
    {
        echo "NAME|VERSION|PORT|TAG|STATE|SERVICE|DATA DIRECTORY"
        for i in "${!E_NAME[@]}"; do
            echo "${E_NAME[$i]}|${E_VER[$i]}|${E_PORT[$i]}|${E_TAG[$i]}|$(entry_state "${E_DATA[$i]}")|${E_SVC[$i]}|${E_DATA[$i]}"
        done
    } | awk -F'|' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n = NR; nf = NF }
        END { for (r = 1; r <= n; r++) { l = ""
                  for (i = 1; i <= nf; i++) l = l sprintf(i < nf ? "%-" w[i] + 2 "s" : "%s", c[r, i])
                  print l } }'
    for i in "${BAD_LINES[@]+"${BAD_LINES[@]}"}"; do say "WARNING malformed $i"; done
    return 0
}

cmd_check() {
    local i data ver port svc lp cp pgv state up drift=0 line d
    [[ $# -eq 0 ]] || die "check takes no options"
    read_registry
    if (( EUID != 0 )) && [[ $(id -un) != "$(dir_owner)" ]]; then
        say "NOTE  run as $(id -un): clusters owned by other users may be partly unreadable"
    fi
    if [[ ! -f $EPASTAB ]]; then
        say "DRIFT no registry file ($EPASTAB)"; drift=1
    fi
    for i in "${BAD_LINES[@]+"${BAD_LINES[@]}"}"; do say "DRIFT malformed $i"; drift=1; done

    for i in "${!E_NAME[@]}"; do
        data=${E_DATA[$i]} ver=${E_VER[$i]} port=${E_PORT[$i]} svc=${E_SVC[$i]}
        d="${E_NAME[$i]}:"
        if [[ ! -d $data ]]; then
            say "DRIFT $d data directory $data does not exist"; drift=1; continue
        fi
        if [[ -r $data/PG_VERSION ]]; then
            pgv=$(tr -d '[:space:]' < "$data/PG_VERSION")
            if [[ $pgv != "$ver" ]]; then say "DRIFT $d PG_VERSION is $pgv, registry says $ver"; drift=1; fi
        elif [[ -r $data ]]; then
            say "DRIFT $d $data has no PG_VERSION (not a cluster)"; drift=1
        else
            say "NOTE  $d $data not readable as $(id -un) - run as the cluster owner or root for full checks"
        fi
        state=$(entry_state "$data")
        lp=$(live_port "$data")
        if [[ -n $lp ]]; then
            if [[ $lp != "$port" ]]; then say "DRIFT $d running on port $lp, registry says $port"; drift=1; fi
        else
            cp=$(conf_port "$data")
            if [[ -n $cp && $cp != "$port" ]]; then say "DRIFT $d configured port is $cp, registry says $port"; drift=1; fi
        fi
        if [[ $svc != "-" ]] && have_systemd; then
            if ! unit_loaded "$svc"; then
                say "DRIFT $d service $svc is not installed"; drift=1
            else
                up=$(unit_pgdata "$svc")
                if [[ -n $up && $(canon "$up") != "$(canon "$data")" ]]; then
                    say "DRIFT $d service $svc runs PGDATA=$up, not $data"; drift=1
                fi
            fi
        fi
        say "INFO  $d ${E_TAG[$i]}, $state"
    done

    # Running clusters the registry does not know about
    while IFS= read -r line; do
        IFS='|' read -r ver d port _ _ _ <<< "$line"
        local known=0
        for i in "${!E_DATA[@]}"; do
            if [[ $(canon "${E_DATA[$i]}") == "$(canon "$d")" ]]; then known=1; break; fi
        done
        if (( ! known )); then say "DRIFT running cluster not registered: version $ver, $d, port $port"; drift=1; fi
    done < <(list_epas_instances)

    if (( drift )); then say "RESULT drift found"; return 2; fi
    say "RESULT registry matches this host"
    return 0
}

cmd_import() {
    local tag="" dry=0 line ver data port pid owner mgr svc name base u i
    local -a plan=() seen=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            --tag)     optval "$@"; tag=${2^^}; shift 2 ;;
            --dry-run) dry=1; shift ;;
            *) die "import: unknown option '$1' (see --help)" ;;
        esac
    done
    [[ -n $tag ]] || die "import needs --tag ($TAGS) - the environment cannot be detected"
    [[ " $TAGS " == *" $tag "* ]] || die "Invalid tag '$tag': one of $TAGS"
    (( EUID == 0 )) || log_info "Running as $(id -un): clusters owned by other users may be skipped"
    read_registry
    (( dry )) || need_write_access          # fail before showing a plan that cannot be written

    # Candidates: running clusters, plus installed edb-as-* units (catches stopped ones)
    local -a cand=()
    while IFS= read -r line; do
        IFS='|' read -r ver data port pid owner mgr <<< "$line"
        svc="-"; [[ $mgr == systemd:* ]] && svc=${mgr#systemd:}; svc=${svc%.service}
        cand+=("$ver|$data|$port|$svc")
    done < <(list_epas_instances)
    if have_systemd; then
        while IFS= read -r u; do
            [[ -n $u ]] || continue
            u=${u%.service}
            data=$(unit_pgdata "$u")
            [[ -n $data && -d $data ]] || continue
            ver=$(tr -d '[:space:]' < "$data/PG_VERSION" 2>/dev/null || true)
            cand+=("${ver:-?}|$data|?|$u")
        done < <(systemctl list-unit-files 'edb-as-*.service' --no-legend 2>/dev/null | awk '{print $1}' | grep -v '@' || true)
    fi

    for line in "${cand[@]+"${cand[@]}"}"; do
        IFS='|' read -r ver data port svc <<< "$line"
        data=$(canon "$data")
        [[ " ${seen[*]+"${seen[*]}"} " == *" $data "* ]] && continue
        seen+=("$data")
        for i in "${!E_DATA[@]}"; do
            if [[ $(canon "${E_DATA[$i]}") == "$data" ]]; then
                log_info "Already registered: $data as '${E_NAME[$i]}'"; continue 2
            fi
        done
        if [[ $ver == "?" || -z $ver ]]; then
            log_warn "Skipping $data: version unknown (run as the cluster owner or root)"; continue
        fi
        if [[ $port == "?" || -z $port ]]; then port=$(live_port "$data"); fi
        if [[ -z $port ]]; then port=$(conf_port "$data"); fi
        if [[ -z $port ]]; then
            log_warn "Skipping $data: port unknown (run as the cluster owner or root, or use 'add --port')"; continue
        fi
        if [[ $svc == "-" ]]; then svc=$(guess_service "$ver" "$data"); fi
        # Name: the data directory's name if it follows the convention, else as<ver>
        base=$(basename "$data")
        if [[ $base =~ $NAME_RE && ${BASH_REMATCH[1]} == "$ver" ]]; then name=$base; else name="as$ver"; fi
        if [[ -n $(find_entry "$name") || " ${plan[*]+"${plan[*]}"} " == *" $name:"* ]]; then
            log_warn "Skipping $data: name '$name' is taken - register it with 'add --name as${ver}_<suffix>'"; continue
        fi
        plan+=("$name:$ver:$data:$port:$svc:$tag")
    done

    if (( ${#plan[@]} == 0 )); then
        log_info "Nothing to import"; return 0
    fi
    say "Clusters to register in $EPASTAB:"
    printf '  %s\n' "${plan[@]}"
    if (( dry )); then say "(dry run - nothing written)"; return 0; fi

    need_write_access
    take_lock
    read_registry
    confirm_or_exit "register ${#plan[@]} cluster(s) in $EPASTAB with tag $tag"
    for line in "${plan[@]}"; do
        IFS=: read -r name ver data port svc tag <<< "$line"
        validate "$name" "$ver" "$data" "$port" "$svc" "$tag"
        E_NAME+=("$name") E_VER+=("$ver") E_DATA+=("$data") E_PORT+=("$port") E_SVC+=("$svc") E_TAG+=("$tag")
    done
    write_registry
    log_audit "epastab: imported ${#plan[@]} cluster(s) into $EPASTAB: ${plan[*]}"
}

# init: one-time root setup of the registry directory, owned by the database OS user.
# The owner comes from --owner, or SYSTEM_USER/SYSTEM_GROUP in conf/site.env (--env <file>).
cmd_init() {
    local owner="" user group d f cur
    while [[ $# -gt 0 ]]; do
        case $1 in
            --owner) optval "$@"; owner=$2; shift 2 ;;
            *) die "init: unknown option '$1' (see --help)" ;;
        esac
    done
    require_root
    if [[ -n $owner ]]; then
        user=${owner%%:*}
        id "$user" >/dev/null 2>&1 || die "OS user '$user' does not exist on this host"
        if [[ $owner == *:* ]]; then group=${owner#*:}; else group=$(id -gn "$user" 2>/dev/null || true); fi
    else
        load_env required                 # conf/site.env or --env <file>
        user=$SYSTEM_USER group=$SYSTEM_GROUP
    fi
    [[ -n $user && -n $group ]] || die "Cannot determine owner (use --owner USER[:GROUP])"
    id "$user" >/dev/null 2>&1 || die "OS user '$user' does not exist on this host"
    getent group "$group" >/dev/null 2>&1 || die "OS group '$group' does not exist on this host"
    [[ $user != root ]] || die "The registry owner must be the database OS user, not root"

    d=$(reg_dir)
    if [[ -d $d ]]; then
        cur=$(stat -c '%U:%G %a' "$d")
        if [[ $cur == "$user:$group 755" ]]; then
            log_info "$d already set up (owner $user:$group, mode 755) - nothing to do"
            return 0
        fi
        confirm_or_exit "change $d from $cur to $user:$group 755 (registry files inside follow)"
    else
        confirm_or_exit "create $d owned by $user:$group, mode 755 - the database user then maintains $EPASTAB without root"
    fi
    install -d -o "$user" -g "$group" -m 755 "$d"
    for f in "$EPASTAB" "${EPASTAB}.prev" "${EPASTAB}.lock"; do
        if [[ -e $f ]]; then chown "$user:$group" "$f"; fi
    done
    log_audit "epastab: registry directory $d ready, owner $user:$group (mode 755)"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
ACTION=${1:-}
[[ $# -gt 0 ]] && shift
# --env <file> is the toolkit's config-file option; only 'init' reads the config
if [[ -n ${ENV_FILE:-} && $ACTION != init ]]; then
    die "--env is the toolkit's config-file option (used by 'init'); the environment tag is --tag (DEV|SIT|PAT|PROD)"
fi
case $ACTION in
    init)   cmd_init "$@" ;;
    add)    cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    list)   cmd_list "$@" ;;
    check)  cmd_check "$@" ;;
    import) cmd_import "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "Unknown action '$ACTION' (init | add | remove | list | check | import; see --help)" ;;
esac
