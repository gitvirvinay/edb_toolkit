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

    if [ -z "$ENV_SOURCE" ]; then
        log_warn "No conf/site.env found — using built-in defaults (EPAS ${EPAS_VERSION}, service ${SERVICE_NAME}, EFM ${EFM_VERSION}). Run 'make env' to set your real values."
    fi
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

# wait_for_epas [tries] [seconds] — pg_isready on PRIMARY_PORT as SYSTEM_USER; returns 1 on timeout
wait_for_epas() {
    local tries="${1:-12}" secs="${2:-5}" i bin
    bin="${SRC_BINARY_DIR:-/usr/edb/as${EPAS_VERSION}}/bin/pg_isready"
    [ -x "$bin" ] || bin="pg_isready"
    for ((i = 1; i <= tries; i++)); do
        if sudo -u "$SYSTEM_USER" "$bin" -q -p "$PRIMARY_PORT"; then
            log_info "EPAS is accepting connections on port ${PRIMARY_PORT}."
            return 0
        fi
        log_warn "Waiting for EPAS on port ${PRIMARY_PORT}... (${i}/${tries})"
        sleep "$secs"
    done
    return 1
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
