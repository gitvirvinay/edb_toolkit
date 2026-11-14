#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — shared start-up helpers for every edb_toolkit script
#
# In a script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../../lib/common.sh"     # also loads lib/logger.sh
#   parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
#   load_env required      # change-making scripts: stop if no config found
#   load_env optional      # read-only scripts: fall back to defaults, with a warning
#   show_config EPAS_VERSION SERVICE_NAME DATA_TOP ...
#
# Config file lookup (first match wins):
#   1. --env <file>  or  --env=<file>  or a first argument ending in .env
#   2. conf/site.env in this repo
#   3. none -> 'required' stops; 'optional' warns and uses built-in defaults
# load_env also checks SITE, HA_TOOL, BACKUP_TOOL and APP_CODE (validate_settings) and stops on a
# value outside its list.
# Values in the config file take precedence over variables exported in the shell.
# =============================================================================

TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/logger.sh
source "${TOOLKIT_ROOT}/lib/logger.sh"

ENV_FILE="${ENV_FILE:-}"
ENV_SOURCE=""
ASSUME_YES="${ASSUME_YES:-0}"
REMAINING_ARGS=()

die() { log_error "$*"; exit 1; }

# Pull --env and --yes out of the arguments; everything else is left in REMAINING_ARGS.
parse_common_args() {
    REMAINING_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --env)   [ -n "${2:-}" ] || die "--env needs a file path"; ENV_FILE="$2"; shift 2 ;;
            --env=*) ENV_FILE="${1#--env=}"; shift ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            *)       REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
    # Backward compatible: 'script conf/site.env' (env file as first argument)
    if [ -z "$ENV_FILE" ] && [ "${#REMAINING_ARGS[@]}" -gt 0 ] \
       && [[ "${REMAINING_ARGS[0]}" == *.env ]] && [ -f "${REMAINING_ARGS[0]}" ]; then
        ENV_FILE="${REMAINING_ARGS[0]}"
        REMAINING_ARGS=("${REMAINING_ARGS[@]:1}")
    fi
}

# load_env required|optional
load_env() {
    local mode="${1:-required}"
    if [ -n "$ENV_FILE" ]; then
        [ -f "$ENV_FILE" ] || die "Config file not found: $ENV_FILE"
        ENV_SOURCE="$ENV_FILE"
    elif [ -f "${TOOLKIT_ROOT}/conf/site.env" ]; then
        ENV_SOURCE="${TOOLKIT_ROOT}/conf/site.env"
    elif [ "$mode" = "required" ]; then
        die "No config found. Create it with 'make env' (or cp conf/site.env.example conf/site.env), edit it, then re-run — or pass --env <file>."
    else
        ENV_SOURCE=""
    fi

    if [ -n "$ENV_SOURCE" ]; then
        # shellcheck disable=SC1090
        source "$ENV_SOURCE"
        log_init                                   # the log directory may come from this file
        log_info "Config loaded: ${ENV_SOURCE}"
    fi

    # Version-derived defaults — no hard-coded service names in scripts.
    EPAS_VERSION="${EPAS_VERSION:-17}"
    EFM_VERSION="${EFM_VERSION:-5.3}"
    SERVICE_NAME="${SERVICE_NAME:-edb-as-${EPAS_VERSION}}"
    EPAS_SERVICE="${EPAS_SERVICE:-${SERVICE_NAME}}"
    EFM_SERVICE="${EFM_SERVICE:-edb-efm-${EFM_VERSION}}"
    SYSTEM_USER="${SYSTEM_USER:-enterprisedb}"
    SYSTEM_GROUP="${SYSTEM_GROUP:-${SYSTEM_USER}}"
    PRIMARY_PORT="${PRIMARY_PORT:-5444}"
    EFM_CLUSTER_NAME="${EFM_CLUSTER_NAME:-efm}"

    # What this cluster is and which tools it uses (conf/site.env.example). The defaults keep a
    # config file written before these settings existed working exactly as it did.
    APP_CODE="${APP_CODE:-}"
    SITE="$(_lower "${SITE:-primary}")"
    HA_TOOL="$(_lower "${HA_TOOL:-efm}")"
    BACKUP_TOOL="$(_lower "${BACKUP_TOOL:-basebackup}")"
    validate_settings

    if [ -z "$ENV_SOURCE" ]; then
        log_warn "No conf/site.env found — using built-in defaults (EPAS ${EPAS_VERSION}, service ${SERVICE_NAME}, EFM ${EFM_VERSION}). Run 'make env' to set your real values."
    fi
}

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _one_of VALUE CHOICE... — 0 if VALUE is one of the choices
_one_of() {
    local value="$1" choice; shift
    for choice in "$@"; do
        if [ "$value" = "$choice" ]; then return 0; fi
    done
    return 1
}

# validate_settings — stop before anything is changed if a setting has a value outside its list.
# Called by load_env. Every wrong setting is reported in one message, not one per run.
validate_settings() {
    local bad=()
    _one_of "$SITE" primary dr                               || bad+=("SITE='${SITE}' (allowed: primary, dr)")
    _one_of "$HA_TOOL" efm none                              || bad+=("HA_TOOL='${HA_TOOL}' (allowed: efm, none)")
    _one_of "$BACKUP_TOOL" basebackup barman pgbackrest none || bad+=("BACKUP_TOOL='${BACKUP_TOOL}' (allowed: basebackup, barman, pgbackrest, none)")
    if [ -n "$APP_CODE" ] && ! [[ "$APP_CODE" =~ ^[A-Za-z0-9_-]+$ ]]; then
        bad+=("APP_CODE='${APP_CODE}' (letters, digits, _ and - only)")
    fi
    if [ "${#bad[@]}" -gt 0 ]; then
        die "Invalid setting(s) in ${ENV_SOURCE:-the environment}: ${bad[*]}. Nothing was changed."
    fi
    return 0
}

# efm_agents_running — names of the EFM agent services that are active on this host ('' = none).
# Read-only, needs no root. edb-efm-<version> is the packaged unit, efm-<cluster> an extra cluster's.
efm_agents_running() {
    local units
    units="$(systemctl list-units --type=service --state=active --no-legend --plain 'edb-efm-*' 'efm-*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')" || units=""
    printf '%s' "${units% }"
}

# require_no_efm_agent — for HA_TOOL=none, before EPAS is stopped.
# If an agent is running after all, the setting is wrong: EFM would see the database go down
# and could fail over. Stop here, while nothing has been changed.
require_no_efm_agent() {
    local agents
    agents="$(efm_agents_running)"
    if [ -n "$agents" ]; then
        die "HA_TOOL=none, but an EFM agent is running on this host (${agents}). Stopping EPAS under a running agent looks like a database failure to EFM and can cause a failover. Set HA_TOOL=\"efm\" in ${ENV_SOURCE:-the config}, or stop and disable that agent first. Nothing was changed."
    fi
    return 0
}

# show_config VAR...  — print the values this run will use (secrets masked)
show_config() {
    local v val
    log_info "Using settings from: ${ENV_SOURCE:-built-in defaults}"
    for v in "$@"; do
        val="${!v-<unset>}"
        case "$v" in *PASS*|*SECRET*|*TOKEN*) [ "$val" = "<unset>" ] || val="********" ;; esac
        log_info "  ${v}=${val}"
    done
}

# require_vars VAR... — stop if any listed setting is empty
require_vars() {
    local v missing=()
    for v in "$@"; do [ -n "${!v:-}" ] || missing+=("$v"); done
    [ "${#missing[@]}" -eq 0 ] || die "Missing required setting(s) in ${ENV_SOURCE:-config}: ${missing[*]}"
}

require_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root (sudo)."; }

# confirm_or_exit "what is about to happen"
#   Interactive terminal: asks "Proceed? (y/N)" unless --yes was given.
#   Non-interactive (cron/Ansible): proceeds, as before.
confirm_or_exit() {
    local answer
    if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
        log_info "Proceeding: $*"
        return 0
    fi
    read -r -p "About to: $* — Proceed? (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "Cancelled by user."
    log_audit "Confirmed by $(whoami): $*"
}

# confirm_destructive "what is about to happen"
#   For actions that cannot be undone (wipe a server, drop a cluster). Stronger than confirm_or_exit:
#   - on a terminal: shows the host name and asks the operator to type it back exactly;
#   - not on a terminal (cron, Ansible, a pipe): refuses unless --yes was given. An irreversible
#     action must be asked for explicitly; it must never happen because nobody was there to say no.
confirm_destructive() {
    local host answer
    host="$(hostname -s 2>/dev/null || hostname)"
    if [ "$ASSUME_YES" = "1" ]; then
        log_audit "Destructive action on ${host} accepted with --yes by $(whoami): $*"
        return 0
    fi
    [ -t 0 ] || die "Not on a terminal: '$*' needs --yes to run unattended."
    log_warn "About to: $*"
    log_warn "This cannot be undone. Type the host name '${host}' to continue; anything else stops."
    read -r -p "Host name: " answer
    [ "$answer" = "$host" ] || die "Cancelled: '${answer}' is not '${host}'."
    log_audit "Destructive action on ${host} confirmed by $(whoami): $*"
}

# run_as_db_user CMD... — run a command as SYSTEM_USER (the database OS user).
# Already that user (the normal DBA run): the command runs directly, with no sudo - the DBA has
# no sudo rule for "sudo -u enterprisedb", and needs none. Root (or another user): through 'sudo -u'.
run_as_db_user() {
    if [ "$(id -un)" = "${SYSTEM_USER:?SYSTEM_USER is not set}" ]; then
        "$@"
    else
        sudo -u "$SYSTEM_USER" "$@"
    fi
}

# epas_cmd NAME — full path of an EPAS program (psql, edb_sqlpatch, pg_isready ...); NAME alone (found on PATH) if not there
epas_cmd() {
    local bin="${SRC_BINARY_DIR:-/usr/edb/as${EPAS_VERSION}}/bin/$1"
    [ -x "$bin" ] || bin="$1"
    printf '%s\n' "$bin"
}

# wait_for_epas [tries] [seconds] — pg_isready on PRIMARY_PORT as SYSTEM_USER; returns 1 on timeout
wait_for_epas() {
    local tries="${1:-12}" secs="${2:-5}" i bin
    bin="$(epas_cmd pg_isready)"
    for ((i = 1; i <= tries; i++)); do
        if run_as_db_user "$bin" -q -p "$PRIMARY_PORT"; then
            log_info "EPAS is accepting connections on port ${PRIMARY_PORT}."
            return 0
        fi
        log_warn "Waiting for EPAS on port ${PRIMARY_PORT}... (${i}/${tries})"
        sleep "$secs"
    done
    return 1
}

# epas_pkg_version — installed version-release of the EPAS server package ('' if rpm cannot tell)
epas_pkg_version() {
    local v
    v="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "edb-as${EPAS_VERSION}-server" 2>/dev/null)" || return 0
    printf '%s\n' "$v"
}

# patch_state_file — where node-maintenance-stop.sh notes the package version it saw ('' = no log directory)
patch_state_file() {
    local d
    d="$(log_dir)"
    [ -z "$d" ] || printf '%s\n' "${d}/patching/$(hostname -s)_${EPAS_SERVICE}.version"
}

# vip_status — say where the EFM virtual IP is, if this cluster uses one. Information only: a
# standby legitimately does not have it, and many clusters use a connection string, not a VIP.
vip_status() {
    if [ -z "${VIP_ADDRESS:-}" ]; then
        log_info "VIP_ADDRESS is not set: no virtual IP check (clients connect by connection string)"
    elif ip addr show "${VIP_INTERFACE:-eth0}" 2>/dev/null | grep -qF "$VIP_ADDRESS"; then
        log_info "VIP ${VIP_ADDRESS} is on this node (${VIP_INTERFACE:-eth0})"
    else
        log_info "VIP ${VIP_ADDRESS} is not on this node (normal for a standby)"
    fi
}

# efm_bin — path to the efm command for EFM_VERSION (falls back to 'efm' on PATH)
efm_bin() {
    local b="${EFM_BIN:-/usr/edb/efm-${EFM_VERSION}/bin/efm}"
    [ -x "$b" ] && echo "$b" || echo "efm"
}

# set_property KEY VALUE FILE — Java-style key=value files (efm.properties ...).
# Replaces the first KEY= line (also a commented-out '#KEY=' one), drops later duplicates, appends if missing.
# Exact key match (dots are literal); the value is written as-is; file mode/owner are kept.
set_property() {
    local tmp; tmp=$(mktemp)
    K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; n = length(k) }
        { l = $0; sub(/^[[:space:]#]*/, "", l)
          if (substr(l, 1, n) == k && substr(l, n + 1) ~ /^[[:space:]]*=/) { if (!d) { print k "=" v; d = 1 }; next }
          print }
        END { if (!d) print k "=" v }' "$3" > "$tmp" && cat "$tmp" > "$3"
    rm -f "$tmp"
}

# get_property KEY FILE — value of the last uncommented KEY= line (empty if none)
get_property() {
    K="$1" awk 'BEGIN { k = ENVIRON["K"]; n = length(k) }
        { l = $0; sub(/^[[:space:]]*/, "", l)
          if (substr(l, 1, n) == k && substr(l, n + 1) ~ /^[[:space:]]*=/) { sub(/^[^=]*=[[:space:]]*/, "", l); val = l } }
        END { print val }' "$2"
}
