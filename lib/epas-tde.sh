#!/usr/bin/env bash
# =============================================================================
# lib/epas-tde.sh - checks on the TDE key commands, shared by the upgrade and standby scripts
#
#   source lib/epas-tde.sh
#   epas_tde_passfile CMD                 the file named by "-pass file:PATH" in CMD ('' if none)
#   epas_tde_check_unwrap CMD DATADIR     report lines for an unwrap command (see below)
#   epas_tde_same_passphrase FILE1 FILE2  0 = same content, 1 = different, 2 = cannot compare
#
# epas_tde_check_unwrap prints one line per finding, starting with OK, WARN or ERROR, and returns
# 1 when there is at least one ERROR. It only looks at the file's name, owner-mode and place; it
# never prints the passphrase. Why these rules:
#   - the passphrase file must NOT be inside the data directory: pg_basebackup would copy it into
#     every backup, standby and restore copy, next to the data it protects;
#   - "-pass pass:..." puts the passphrase in the command, which is stored in postgresql.conf and
#     shows in the process list.
# A command that does not use a passphrase file (a Thales CipherTrust call, say) is reported as a
# WARN: it cannot be checked here, and is not an error.
# =============================================================================

[ -n "${BASH_VERSION:-}" ] || { echo "epas-tde.sh needs bash" >&2; return 1 2>/dev/null || exit 1; }
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    echo "lib/epas-tde.sh is a library: load it with 'source'." >&2
    exit 2
fi

# epas_tde_passfile CMD -> PATH from "-pass file:PATH" (quotes removed), or nothing.
epas_tde_passfile() {
    local cmd=${1:-} re='-pass[[:space:]]+["'\'']?file:([^[:space:]"'\'']+)'
    if [[ $cmd =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
    return 0
}

# epas_tde_check_unwrap CMD DATADIR
epas_tde_check_unwrap() {
    local cmd=${1:-} data=${2:-} f rc=0 mode
    if [[ -z $cmd ]]; then
        echo "ERROR no TDE unwrap command is set (data_encryption_key_unwrap_command): the server cannot read its key"
        return 1
    fi
    if [[ $cmd =~ -pass[[:space:]]+[\"\']?pass: ]]; then
        echo "ERROR the unwrap command contains the passphrase itself (-pass pass:...): use -pass file:<path outside the data directory>"
        rc=1
    fi
    f=$(epas_tde_passfile "$cmd")
    if [[ -z $f ]]; then
        [[ $rc -eq 0 ]] && echo "WARN  the unwrap command does not use a passphrase file: not checked here"
        return "$rc"
    fi
    if [[ ! -e $f ]]; then
        echo "ERROR passphrase file ${f} does not exist on this host"
        return 1
    fi
    if [[ ! -r $f ]]; then
        echo "ERROR passphrase file ${f} is not readable by $(whoami)"
        return 1
    fi
    if [[ -n $data ]]; then
        case "$(readlink -m "$f")/" in
            "$(readlink -m "$data")"/*)
                echo "ERROR passphrase file ${f} is inside the data directory ${data}: every backup and standby would carry it. Move it to /etc/edb/tde"
                rc=1 ;;
        esac
    fi
    mode=$(stat -c '%a' "$f" 2>/dev/null || echo "")
    if [[ -n $mode ]] && (( (8#$mode & 8#077) != 0 )); then
        echo "WARN  passphrase file ${f} has mode ${mode}: group or others can read it (use 600 or 400)"
    fi
    [[ $rc -eq 0 ]] && echo "OK    passphrase file ${f} exists, is readable and is outside the data directory"
    return "$rc"
}

# epas_tde_same_passphrase FILE1 FILE2 -> 0 same content, 1 different, 2 cannot compare.
# Uses cmp -s: nothing is printed or copied.
epas_tde_same_passphrase() {
    [[ -r ${1:-} && -r ${2:-} ]] || return 2
    if cmp -s "$1" "$2"; then return 0; else return 1; fi
}
