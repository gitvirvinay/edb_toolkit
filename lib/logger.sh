#!/usr/bin/env bash
# =============================================================================
# lib/logger.sh - central logger for every edb_toolkit script (sourced, not run)
#
#   source lib/logger.sh            (lib/common.sh does this for you)
#   log_info "message"    log_warn ...    log_error ...    log_debug ...    log_audit ...
#
# Every message is printed on the screen. It is also written to:
#
#   1. A log FILE, one per run:   <log dir>/<date>-<time>_<script>_<pid>.log
#      <log dir> is the first of these that is set:
#        TOOLKIT_LOG_DIR            a full path, when you want another place
#        <LOG_MOUNT>/toolkit        the log mount from conf/site.env (/pglog/toolkit)
#        /pglog/toolkit             when LOG_MOUNT is not set at all
#      LOG_MOUNT="" (a server without a log mount) means: no directory, unless
#      TOOLKIT_LOG_DIR is set.
#      Root creates the directory ONCE, owned by the database OS user. This library never
#      uses sudo and never changes permissions. When the directory is missing or not
#      writable it says so once, and the messages go to the screen only.
#      New files are readable by owner and group only (mode 640).
#      A script started by another toolkit script writes to the same file when it can.
#
#   2. SYSLOG, only when TOOLKIT_SYSLOG=yes (default: no).
#
# The settings come from conf/site.env or from the environment.
# =============================================================================
set -euo pipefail

SCRIPT_NAME="${0##*/}"
LOG_FACILITY="local0"
LOG_TAG="edb-toolkit"

_LOG_STAMP="$(date '+%Y%m%d-%H%M%S')"   # start time of this run, used in the file name
_LOG_FILE=""                            # the file this run writes to ('' = none yet)
_LOG_PENDING=""                         # messages logged before a file could be opened
_LOG_WARNED=0                           # the "no log file" notice is printed only once

# log_dir - print the directory the log file belongs in ('' = there is none)
log_dir() {
    if [ -n "${TOOLKIT_LOG_DIR:-}" ]; then
        printf '%s\n' "$TOOLKIT_LOG_DIR"
    elif [ -n "${LOG_MOUNT:-}" ]; then
        printf '%s\n' "${LOG_MOUNT}/toolkit"
    elif [ -z "${LOG_MOUNT+set}" ]; then
        printf '%s\n' "/pglog/toolkit"
    fi
    return 0
}

# log_init [quiet] - open the log file for this run.
#   Runs when this library is loaded, again from load_env (lib/common.sh) once conf/site.env
#   has been read, and from the first message if no file is open yet. Calling it again is
#   harmless: it only does something when no file is open, or the directory has changed.
#   'quiet' = do not print the "no log file" notice (used while the settings are not loaded yet).
log_init() {
    local quiet="${1:-}" dir file

    # Started by another toolkit script whose log file we can write to: use that file.
    if [ -z "${_LOG_FILE:-}" ] && [ -n "${TOOLKIT_LOG_FILE:-}" ] && [ -w "${TOOLKIT_LOG_FILE}" ]; then
        _LOG_FILE="$TOOLKIT_LOG_FILE"
        return 0
    fi

    dir="$(log_dir)"
    if [ -n "${_LOG_FILE:-}" ] && { [ -z "$dir" ] || [ "${_LOG_FILE%/*}" = "$dir" ]; }; then
        return 0                                    # a file is open and it is in the right place
    fi

    if [ -z "$dir" ] || [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        if [ -z "${_LOG_FILE:-}" ] && [ -z "$quiet" ] && [ "${_LOG_WARNED:-0}" = "0" ]; then
            _LOG_WARNED=1
            echo "[logger] No log file for this run: '${dir:-<no log directory set>}' is not a writable directory - messages go to the screen only. Root creates it once, owned by the database OS user; or set TOOLKIT_LOG_DIR." >&2
        fi
        return 0
    fi

    file="${dir}/${_LOG_STAMP:-$(date '+%Y%m%d-%H%M%S')}_${SCRIPT_NAME%.sh}_$$.log"
    if ( umask 027; : >> "$file" ) 2>/dev/null; then
        _LOG_FILE="$file"
        export TOOLKIT_LOG_FILE="$file"
        if [ -n "${_LOG_PENDING:-}" ]; then
            printf '%s' "$_LOG_PENDING" >> "$_LOG_FILE" 2>/dev/null || true
            _LOG_PENDING=""
        fi
    fi
    return 0
}

# _log_write LINE - screen, then the log file (or the waiting list until a file is open)
_log_write() {
    echo "$1"
    if [ -z "${_LOG_FILE:-}" ]; then log_init; fi
    if [ -n "${_LOG_FILE:-}" ]; then
        echo "$1" >> "$_LOG_FILE" 2>/dev/null || true
    elif [ "${#_LOG_PENDING}" -lt 20000 ]; then
        _LOG_PENDING+="$1"$'\n'
    fi
    return 0
}

# _log_syslog PRIORITY TAG MESSAGE - copy to syslog when TOOLKIT_SYSLOG=yes
_log_syslog() {
    if [ "${TOOLKIT_SYSLOG:-no}" = "yes" ]; then
        logger -p "${LOG_FACILITY:-local0}.$1" -t "$2" "[${SCRIPT_NAME:-edb-toolkit}] $3" 2>/dev/null || true
    fi
    return 0
}

log_raw() {
    local level="$1" label; shift
    local message="$*"
    case "$level" in                       # label shown in the line (works on old bash too)
        debug) label=DEBUG ;; info) label=INFO ;; warn) label=WARN ;; err) label=ERR ;;
        *)     label="$level" ;;
    esac
    _log_write "[$(date '+%F %T.%3N')] [${label}] [${SCRIPT_NAME:-edb-toolkit}] ${message}"
    _log_syslog "$level" "${LOG_TAG:-edb-toolkit}" "$message"
}

log_debug() { log_raw "debug" "$@"; }
log_info()  { log_raw "info"  "$@"; }
log_warn()  { log_raw "warn"  "$@"; }
log_error() { log_raw "err"   "$@"; }

# log_audit - a change was made: who did what. Same destinations, marked [AUDIT].
log_audit() {
    local message="$*"
    _log_write "[$(date '+%F %T.%3N')] [AUDIT] [${SCRIPT_NAME:-edb-toolkit}] ${message}"
    _log_syslog "notice" "${LOG_TAG:-edb-toolkit}-audit" "$message"
}

# log_file - print the path of this run's log file ('' when there is none)
log_file() { printf '%s\n' "${_LOG_FILE:-}"; }

log_init quiet

export -f log_dir log_init _log_write _log_syslog log_raw log_debug log_info log_warn log_error log_audit log_file
