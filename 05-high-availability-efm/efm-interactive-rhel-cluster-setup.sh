#!/usr/bin/env bash
# Interactive EDB Failover Manager installer/configurator for RHEL-family systems.
# Run once on EACH server (primary, standby, and witness).
# Review the generated configuration before starting EFM in production.

set -Eeuo pipefail
umask 077

die() { echo "ERROR: $*" >&2; exit 1; }
info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
  else
    while :; do
      read -r -p "$prompt: " answer
      [[ -n "$answer" ]] && { printf '%s' "$answer"; return; }
      echo "A value is required."
    done
  fi
}
confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}
set_prop() {
  local key="$1" value="$2" file="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { found=0 }
    $0 ~ "^[[:space:]#]*" k "[[:space:]]*=" {
      if (!found) { print k "=" v; found=1 }
      next
    }
    { print }
    END { if (!found) print k "=" v }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }

[[ $EUID -eq 0 ]] || die "Run as root (for example: sudo -i, then run this script)."
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "rhel" || "${ID_LIKE:-}" == *"rhel"* || "${ID:-}" == "rocky" || "${ID:-}" == "almalinux" || "${ID:-}" == "ol" ]] \
  || warn "This script is intended for RHEL and compatible distributions; detected ${PRETTY_NAME:-unknown}."

echo "============================================================"
echo " Interactive EDB Failover Manager (EFM) setup"
echo " Run this script separately on primary, standby, and witness"
echo "============================================================"
echo "This script does NOT create or change streaming replication."
echo "It will install packages and write EFM configuration files."
echo

EFM_VERSION="$(ask 'EFM version (examples: 53 for EFM 5.3, 54 for EFM 5.4)' '53')"
[[ "$EFM_VERSION" =~ ^[0-9]{2}$ ]] || die "Use the two-digit EFM package suffix, e.g. 53."
EFM_PACKAGE="edb-efm${EFM_VERSION}"
EFM_DIR="/etc/edb/efm-${EFM_VERSION:0:1}.${EFM_VERSION:1:1}"
EFM_BIN="/usr/edb/efm-${EFM_VERSION:0:1}.${EFM_VERSION:1:1}/bin"
EFM_SERVICE="edb-efm-${EFM_VERSION:0:1}.${EFM_VERSION:1:1}"

CLUSTER_NAME="$(ask 'EFM cluster name (default service expects efm)' 'efm')"
[[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "Use only letters, numbers, underscore, or hyphen for cluster name."
[[ "$CLUSTER_NAME" == "efm" ]] || die "This script currently supports the default systemd cluster name 'efm' only. Custom cluster names require a matching systemd service/unit configuration."

echo
echo "Select this server's role:"
echo "  1) Primary"
echo "  2) Standby"
echo "  3) Witness"
ROLE="$(ask 'Enter 1, 2, or 3' '1')"
case "$ROLE" in
  1) IS_WITNESS=false; ROLE_NAME=primary ;;
  2) IS_WITNESS=false; ROLE_NAME=standby ;;
  3) IS_WITNESS=true; ROLE_NAME=witness ;;
  *) die "Invalid role." ;;
esac

PRIMARY_IP="$(ask 'Primary server IP/address')"
STANDBY_IP="$(ask 'Standby server IP/address')"
WITNESS_IP="$(ask 'Witness server IP/address')"
BIND_IP="$(case "$ROLE" in 1) echo "$PRIMARY_IP";; 2) echo "$STANDBY_IP";; 3) echo "$WITNESS_IP";; esac)"
BIND_PORT="$(ask 'EFM bind/communication port' '7800')"
valid_port "$BIND_PORT" || die "Invalid EFM port."
ADMIN_PORT="$(ask 'EFM admin port' '7801')"
valid_port "$ADMIN_PORT" || die "Invalid admin port."

DB_PORT="$(ask 'EPAS/PostgreSQL port' '5444')"
valid_port "$DB_PORT" || die "Invalid database port."
DB_USER="$(ask 'EFM database monitoring user (must already exist and have required privileges)' 'efm')"
DB_NAME="$(ask 'Database name for EFM connection' 'edb')"
DB_OWNER=""
DB_SERVICE=""
DB_BIN=""
DB_DATA=""
DB_CONFIG=""
if [[ "$IS_WITNESS" == false ]]; then
  DB_OWNER="$(ask 'OS owner of the database data directory' 'enterprisedb')"
  DB_SERVICE="$(ask 'Database systemd service name (leave blank if not applicable)' '')"
  DB_BIN="$(ask 'Database bin directory (example: /usr/edb/as17/bin)' '/usr/edb/as17/bin')"
  DB_DATA="$(ask 'Database data directory (show data_directory from SQL)' '')"
  DB_CONFIG="$(ask 'Database config file directory (blank if same as data directory)' '')"
fi

echo
info "Installing prerequisites and ${EFM_PACKAGE}"
dnf install -y java-11-openjdk-headless || dnf install -y java-17-openjdk-headless
dnf install -y "$EFM_PACKAGE" || die "Package install failed. Confirm the EDB repository is configured and package ${EFM_PACKAGE} exists."

[[ -x "${EFM_BIN}/efm" ]] || {
  warn "Expected binary ${EFM_BIN}/efm not found. Searching installed paths..."
  FOUND_BIN="$(command -v efm || true)"
  [[ -n "$FOUND_BIN" ]] || die "Could not locate efm executable; verify the installed package/version."
  EFM_BIN="$(dirname "$FOUND_BIN")"
}
[[ -d "$EFM_DIR" ]] || {
  warn "Expected config directory $EFM_DIR not found."
  ls -d /etc/edb/efm-* 2>/dev/null || true
  die "Adjust this script's EFM version/path mapping for the installed package."
}

PROPERTIES="${EFM_DIR}/${CLUSTER_NAME}.properties"
NODES="${EFM_DIR}/${CLUSTER_NAME}.nodes"
TEMPLATE="${EFM_DIR}/efm.properties.in"
NODE_TEMPLATE="${EFM_DIR}/efm.nodes.in"

if [[ -e "$PROPERTIES" || -e "$NODES" ]]; then
  warn "Configuration files already exist for cluster ${CLUSTER_NAME}."
  confirm "Back up existing files and replace them" || die "Cancelled without changing existing configuration."
  stamp="$(date +%Y%m%d%H%M%S)"
  [[ ! -e "$PROPERTIES" ]] || cp -a "$PROPERTIES" "${PROPERTIES}.bak.${stamp}"
  [[ ! -e "$NODES" ]] || cp -a "$NODES" "${NODES}.bak.${stamp}"
fi

if [[ -f "$TEMPLATE" ]]; then
  cp "$TEMPLATE" "$PROPERTIES"
else
  die "Template not found: $TEMPLATE"
fi
if [[ -f "$NODE_TEMPLATE" ]]; then cp "$NODE_TEMPLATE" "$NODES"; else : > "$NODES"; fi

# The same membership list goes on all nodes. EFM nodes entries are host:port.
printf '%s:%s\n%s:%s\n%s:%s\n' "$PRIMARY_IP" "$BIND_PORT" "$STANDBY_IP" "$BIND_PORT" "$WITNESS_IP" "$BIND_PORT" > "$NODES"

# Required/common cluster properties. Keep the template's other version-specific settings intact.
set_prop "bind.address" "${BIND_IP}:${BIND_PORT}" "$PROPERTIES"
set_prop "admin.port" "$ADMIN_PORT" "$PROPERTIES"
set_prop "is.witness" "$IS_WITNESS" "$PROPERTIES"
set_prop "db.port" "$DB_PORT" "$PROPERTIES"
set_prop "auto.allow.hosts" "false" "$PROPERTIES"
set_prop "stable.nodes.file" "true" "$PROPERTIES"

set_prop "db.user" "$DB_USER" "$PROPERTIES"
set_prop "db.database" "$DB_NAME" "$PROPERTIES"
if [[ "$IS_WITNESS" == false ]]; then
  set_prop "db.service.owner" "$DB_OWNER" "$PROPERTIES"
  set_prop "db.bin" "$DB_BIN" "$PROPERTIES"
  set_prop "db.data.dir" "$DB_DATA" "$PROPERTIES"
  [[ -z "$DB_CONFIG" ]] || set_prop "db.config.dir" "$DB_CONFIG" "$PROPERTIES"
  [[ -z "$DB_SERVICE" ]] || set_prop "db.service.name" "$DB_SERVICE" "$PROPERTIES"
fi

chown efm:efm "$PROPERTIES" "$NODES"
chmod 600 "$PROPERTIES" "$NODES"

echo
echo "============================================================"
echo " Database password encryption"
echo "============================================================"
echo "Run the following command and follow its prompt:"
echo "  ${EFM_BIN}/efm encrypt ${CLUSTER_NAME}"
echo "Paste the encrypted result into ${PROPERTIES} as:"
echo "  db.password.encrypted=<encrypted-output>"
echo "Do not put the cleartext database password in this script or properties file."
if [[ "$IS_WITNESS" == true ]]; then
  echo "Witness nodes do not connect to a local database, but the shared cluster configuration may still require database credentials for cluster-wide checks."
fi

echo
echo "============================================================"
echo " Firewall checklist (configure using your approved firewall process)"
echo "============================================================"
echo "Allow EFM TCP ${BIND_PORT} between all three nodes."
echo "Allow EFM admin TCP ${ADMIN_PORT} only from trusted administration hosts as required."
echo "Allow database TCP ${DB_PORT} from EFM primary/standby/witness nodes to the database hosts."
echo "Do not expose EFM ports to untrusted networks."

echo
echo "============================================================"
echo " Configuration review"
echo "============================================================"
echo "Role:        ${ROLE_NAME}"
echo "Cluster:     ${CLUSTER_NAME}"
echo "Properties:  ${PROPERTIES}"
echo "Nodes file:  ${NODES}"
echo
echo "Before starting EFM:"
echo "  1. Ensure primary/standby streaming replication is already configured and healthy."
echo "  2. Configure pg_hba.conf and database credentials so all EFM agents can connect as required."
echo "  3. Add the encrypted DB password to db.password.encrypted where required."
echo "  4. Review all required properties against the guide for your exact EFM version."
echo "  5. Configure firewall rules and test name/IP reachability."
echo
if confirm "Start ${EFM_SERVICE} now on this node? (recommended only after all three nodes are configured and reviewed)"; then
  systemctl enable "$EFM_SERVICE"
  systemctl start "$EFM_SERVICE"
  systemctl --no-pager --full status "$EFM_SERVICE" || true
  echo
  "${EFM_BIN}/efm" cluster-status "$CLUSTER_NAME" || true
else
  echo "Not started. After configuration is complete on all nodes, run:"
  echo "  systemctl enable --now ${EFM_SERVICE}"
  echo "  ${EFM_BIN}/efm cluster-status ${CLUSTER_NAME}"
fi

echo
echo "Done. Review logs with: journalctl -u ${EFM_SERVICE} -b --no-pager"
echo "IMPORTANT: This script configures EFM agents only; it does not provision EPAS, replication, VIP, or pg_hba.conf."
