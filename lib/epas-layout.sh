# shellcheck shell=bash
# =============================================================================
# lib/epas-layout.sh - storage layout (mount points) shared by the build, the standby
# rebuild and the checks.
#
# The layout in conf/site.env: one MOUNT per kind of file, one folder per cluster under it.
#   DATA_TOP     PGDATA                                    /pgdata/<cluster>     required
#   WAL_TOP      pg_wal (initdb / pg_basebackup --waldir)  /pgwal/<cluster>      empty = inside PGDATA
#   ARCHIVE_TOP  archived WAL / pgBackRest async spool     /pgarchive/<cluster>  empty = not used
#   BACKUP_TOP   local base backups                        /pgbackup/<cluster>   empty = not used
#   LOG_TOP      server logs (log_directory)               /pglog/<cluster>      empty = 'log' inside PGDATA
#
#   epas_layout_vars              the *_TOP variable names, in the order above
#   epas_layout_valid_path P      0 if P is an absolute path with safe characters only
#   epas_layout_fs_id P           device id of the filesystem holding P (or its nearest existing parent)
#   epas_layout_fs_target P       mount point of that filesystem (findmnt; '?' if unknown)
#   epas_layout_check             one line per *_TOP that is set:
#                                   "OK    VAR PATH (own filesystem MOUNT)"
#                                   "WARN  VAR PATH ..." when it is on '/' or shares a filesystem it
#                                   should not (WAL/LOG/ARCHIVE/BACKUP with DATA; ARCHIVE with WAL)
#                                 returns 1 if any WARN. Read-only; needs no root.
#   epas_layout_parent_ok P       0 if dirname(P) may be handed to the DB user (not /, /etc, /usr, ...)
#
# epas_layout_fs_id / epas_layout_fs_target can be redefined by tests.
# Safe to source: changes no shell options, never exits the caller.
# =============================================================================

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo "lib/epas-layout.sh is a library: source it" >&2
    exit 2
fi

epas_layout_vars() { echo "DATA_TOP WAL_TOP ARCHIVE_TOP BACKUP_TOP LOG_TOP"; }

epas_layout_valid_path() {
    [[ ${1:-} == /?* && $1 =~ ^[A-Za-z0-9._/+-]+$ && $1 != *..* && $1 != *//* ]]
}

# Nearest existing directory at or above P (findmnt/stat need an existing path).
_epas_layout_existing() {
    local p=${1%/}
    [[ -n $p ]] || p=/
    while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
    echo "$p"
}

epas_layout_fs_id() { stat -c %d "$(_epas_layout_existing "$1")" 2>/dev/null || echo "?"; }

epas_layout_fs_target() {
    local t
    t=$(findmnt -n -o TARGET -T "$(_epas_layout_existing "$1")" 2>/dev/null | head -n1) || t=""
    echo "${t:-?}"
}

# Directories whose ownership the toolkit must never change.
epas_layout_parent_ok() {
    local parent
    parent=$(dirname "${1%/}")
    case "$parent" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib|/var/log|/mnt|/media) return 1 ;;
        /etc/*|/usr/*|/proc/*|/sys/*|/dev/*|/boot/*) return 1 ;;
    esac
    return 0
}

epas_layout_check() {
    local rc=0 var path id target root_id data_id="" wal_id=""
    root_id=$(epas_layout_fs_id /)
    for var in $(epas_layout_vars); do
        path=${!var:-}
        [[ -n $path ]] || continue
        id=$(epas_layout_fs_id "$path")
        target=$(epas_layout_fs_target "$path")
        case "$var" in
            DATA_TOP) data_id=$id ;;
            WAL_TOP)  wal_id=$id ;;
        esac
        if [[ $id == "$root_id" ]]; then
            echo "WARN  $var $path is on the root filesystem (/), not on its own mount"; rc=1
        elif [[ $var != DATA_TOP && -n $data_id && $id == "$data_id" ]]; then
            echo "WARN  $var $path shares a filesystem with DATA_TOP (${target}) - it can fill the data disk, or the data can fill it"; rc=1
        elif [[ $var == ARCHIVE_TOP && -n $wal_id && $id == "$wal_id" ]]; then
            echo "WARN  $var $path shares a filesystem with WAL_TOP (${target}) - a stuck archive can fill pg_wal's disk"; rc=1
        else
            echo "OK    $var $path (own filesystem ${target})"
        fi
    done
    [[ -n ${WAL_TOP:-} ]] || { echo "WARN  WAL_TOP is empty - pg_wal stays inside PGDATA (old layout)"; rc=1; }
    [[ -n ${LOG_TOP:-} ]] || { echo "WARN  LOG_TOP is empty - server logs stay inside PGDATA (old layout)"; rc=1; }
    return $rc
}
