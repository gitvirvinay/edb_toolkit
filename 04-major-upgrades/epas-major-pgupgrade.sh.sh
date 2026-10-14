#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/../config/logger.sh" ]; then
    source "${SCRIPT_DIR}/../config/logger.sh"
else
    log_info()  { echo -e "[INFO] $1"; }
    log_error() { echo -e "[ERROR] $1" >&2; }
    log_audit() { echo -e "[AUDIT] $1"; }
fi

# --- DEFAULT FALLBACK CONFIGURATION ---
OLD_SERVICE="edb-as-14"
NEW_SERVICE="edb-as-17"
OLD_BIN="/usr/edb/as14/bin"
NEW_BIN="/usr/edb/as17/bin"
OLD_DATA="/pgdata/as14/data"
NEW_DATA="/pgdata/as17/data"
EXPECTED_USER="enterprisedb"

USE_LINK=false
REQUIRE_ROOT=false
ENV_FILE=""

# --- PARSE COMMAND LINE ARGUMENTS ---
usage() {
    echo "Usage: $0 [--env <path_to_env>] [--link] [--root]"
    echo "  --env  : Path to deployment environment file (e.g. deploy.env)"
    echo "  --link : Use pg_upgrade hardlinks (fast, minimal space requirement)."
    echo "  --root : Run script as root (commands execute via 'sudo -u <user>')."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        --link)
            USE_LINK=true
            shift
            ;;
        --root)
            REQUIRE_ROOT=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
    esac
done

# --- LOAD ENVIRONMENT FILE IF PROVIDED ---
if [ -n "$ENV_FILE" ]; then
    if [ -f "$ENV_FILE" ]; then
        log_info "Loading environment configuration from: ${ENV_FILE}"
        # Export all variables defined in deploy.env automatically
        set -o allexport
        source "$ENV_FILE"
        set +o allexport

        # Override script variables using values from deploy.env
        [ -n "${SRC_BINARY_DIR:-}" ] && NEW_BIN="${SRC_BINARY_DIR}/bin"
        [ -n "${DATA_TOP:-}" ]       && NEW_DATA="${DATA_TOP}/data"
        [ -n "${SERVICE_NAME:-}" ]   && NEW_SERVICE="${SERVICE_NAME}"
        [ -n "${SYSTEM_USER:-}" ]    && EXPECTED_USER="${SYSTEM_USER}"
    else
        log_error "Specified environment file not found: ${ENV_FILE}"
        exit 1
    fi
fi

# --- USER CONTEXT CHECK ---
CURRENT_USER=$(whoami)
EUID_VAL=$(id -u)

if [ "$REQUIRE_ROOT" = true ]; then
    if [ "$EUID_VAL" -ne 0 ]; then
        log_error "Root mode specified. Script must be executed as root (EUID 0)."
        exit 1
    fi
    EXEC_CMD="sudo -u ${EXPECTED_USER}"
else
    if [ "$CURRENT_USER" == "root" ]; then
        log_error "Do not run as root without the --root flag. Execute as '${EXPECTED_USER}' or pass --root."
        exit 1
    fi
    if [ "$CURRENT_USER" != "$EXPECTED_USER" ]; then
        log_error "Script must be executed as '${EXPECTED_USER}' (currently: ${CURRENT_USER})."
        exit 1
    fi
    EXEC_CMD=""
fi

# --- DISK SPACE CHECK (COPY MODE ONLY) ---
if [ "$USE_LINK" = false ]; then
    log_info "Verifying disk space allocation for copy-mode upgrade..."
    OLD_DATA_SIZE_KB=$(du -s "$OLD_DATA" | awk '{print $1}')
    NEW_DATA_DIR=$(dirname "$NEW_DATA")
    FREE_SPACE_KB=$(df -k "$NEW_DATA_DIR" | awk 'NR==2 {print $4}')

    REQUIRED_SPACE_KB=$(( OLD_DATA_SIZE_KB + (OLD_DATA_SIZE_KB / 10) ))

    if [ "$FREE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
        log_error "Insufficient disk space on ${NEW_DATA_DIR}."
        log_error "Required: ~$(( REQUIRED_SPACE_KB / 1024 )) MB | Free: $(( FREE_SPACE_KB / 1024 )) MB"
        log_error "Aborting: Copy-based upgrade requires enough space for both clusters."
        exit 1
    fi
else
    log_info "Link mode enabled (--link): Skipping strict disk copy space validation."
fi

# --- SECURITY / TDE PASSPHRASE PREPARATION ---
read -p "Have you taken a verified filesystem-level backup of ${OLD_DATA}? (yes/NO): " BACKUP_CONFIRM
[[ "$BACKUP_CONFIRM" == "yes" ]] || { log_error "Aborting -- verified backup required before major migration."; exit 1; }

# Handle TDE Commands from deploy.env or prompt interactively
if [ -n "${TDE_WRAP_CMD:-}" ] && [ -n "${TDE_UNWRAP_CMD:-}" ]; then
    log_info "Using TDE Key Wrap/Unwrap commands defined in deploy.env"
    export PGDATAKEYWRAPCMD="${TDE_WRAP_CMD}"
    export PGDATAKEYUNWRAPCMD="${TDE_UNWRAP_CMD}"
else
    read -s -p "Enter TDE master passphrase: " PGPASSWORD_TDE; echo ""
    TMP_PASS=$(mktemp)
    chmod 600 "$TMP_PASS"
    printf '%s' "$PGPASSWORD_TDE" > "$TMP_PASS"

    export PGDATAKEYWRAPCMD="openssl enc -e -aes-128-cbc -pbkdf2 -pass file:${TMP_PASS} -out %p"
    export PGDATAKEYUNWRAPCMD="openssl enc -d -aes-128-cbc -pbkdf2 -pass file:${TMP_PASS} -in %p"

    cleanup() {
        if [ -f "${TMP_PASS:-}" ]; then
            shred -u "$TMP_PASS" 2>/dev/null || rm -f "$TMP_PASS"
        fi
    }
    trap cleanup EXIT INT TERM HUP
fi

# Move context to universally writable directory
cd /tmp

# Build pg_upgrade command options
UPGRADE_ARGS=(
    "--old-datadir=$OLD_DATA"
    "--new-datadir=$NEW_DATA"
    "--old-bindir=$OLD_BIN"
    "--new-bindir=$NEW_BIN"
)

if [ "$USE_LINK" = true ]; then
    UPGRADE_ARGS+=("--link")
fi

# --- PREFLIGHT RUN (CHECK MODE) ---
log_info "Executing structural compatibility preflight analysis..."
$EXEC_CMD env PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" "${UPGRADE_ARGS[@]}" --check

read -p "Preflight passed. Ready to shut down database services and upgrade? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

# --- SERVICE CONTROL ---
log_info "Stopping database services..."
if [ "$REQUIRE_ROOT" = true ]; then
    systemctl stop "$OLD_SERVICE" || true
    systemctl stop "$NEW_SERVICE" || true
else
    sudo systemctl stop "$OLD_SERVICE" || true
    sudo systemctl stop "$NEW_SERVICE" || true
fi

# --- ACTUAL UPGRADE RUN ---
log_info "Starting database upgrade..."
$EXEC_CMD env PGDATAKEYWRAPCMD="$PGDATAKEYWRAPCMD" PGDATAKEYUNWRAPCMD="$PGDATAKEYUNWRAPCMD" \
    "$NEW_BIN/pg_upgrade" "${UPGRADE_ARGS[@]}"

# --- START NEW SERVICE ---
log_info "Starting new database service (${NEW_SERVICE})..."
if [ "$REQUIRE_ROOT" = true ]; then
    systemctl start "$NEW_SERVICE"
else
    sudo systemctl start "$NEW_SERVICE"
fi

# --- POST-UPGRADE STATS ---
ANALYZE_SCRIPT="${SCRIPT_DIR}/analyze_new_cluster.sh"
if [ -f "$ANALYZE_SCRIPT" ]; then
    log_info "Rebuilding database statistics optimization tables..."
    $EXEC_CMD bash "$ANALYZE_SCRIPT"
elif [ -f "./analyze_new_cluster.sh" ]; then
    log_info "Rebuilding database statistics optimization tables..."
    $EXEC_CMD bash ./analyze_new_cluster.sh
fi

MODE_STR=$([ "$USE_LINK" = true ] && echo "Link-mode" || echo "Copy-mode")
log_audit "Major upgrade completed (${MODE_STR}): ${OLD_DATA} -> ${NEW_DATA}"