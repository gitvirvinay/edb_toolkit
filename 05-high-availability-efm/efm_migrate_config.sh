#!/bin/bash
# update_efm_for_epas17.sh
# Quick EFM reconfiguration for EPAS 15 -> 17 upgrade
# Usage: sudo ./update_efm_for_epas17.sh <path_to_efm.properties>

set -e

PROPS_FILE="$1"
EPAS17_BIN="/usr/edb/epas17/bin"
EPAS17_DATA="/var/lib/edb/epas17/data"
BACKUP_SUFFIX=".backup.$(date +%Y%m%d_%H%M%S)"

# --- Validation ---
if [ -z "$PROPS_FILE" ]; then
    echo "ERROR: Please provide the path to efm.properties"
    echo "Usage: $0 /path/to/efm.properties"
    exit 1
fi

if [ ! -f "$PROPS_FILE" ]; then
    echo "ERROR: File not found: $PROPS_FILE"
    exit 1
fi

if [ ! -d "$EPAS17_BIN" ]; then
    echo "ERROR: EPAS 17 binaries not found at $EPAS17_BIN"
    echo "Please verify EPAS 17 is installed."
    exit 1
fi

# --- Backup ---
echo "Creating backup: ${PROPS_FILE}${BACKUP_SUFFIX}"
cp "$PROPS_FILE" "${PROPS_FILE}${BACKUP_SUFFIX}"

# --- Update properties ---
echo "Updating EFM properties for EPAS 17..."

# Update db.bin (handle both commented and uncommented lines)
sed -i "s|^#db.bin=.*|db.bin=${EPAS17_BIN}|g" "$PROPS_FILE"
sed -i "s|^db.bin=.*|db.bin=${EPAS17_BIN}|g" "$PROPS_FILE"

# Update db.data.dir (handle both commented and uncommented lines)
sed -i "s|^#db.data.dir=.*|db.data.dir=${EPAS17_DATA}|g" "$PROPS_FILE"
sed -i "s|^db.data.dir=.*|db.data.dir=${EPAS17_DATA}|g" "$PROPS_FILE"

# --- Verification ---
echo ""
echo "=== Verification ==="
echo "Updated lines:"
grep -E "^db\.(bin|data\.dir)=" "$PROPS_FILE" || echo "WARNING: Properties not found or still commented"

echo ""
echo "=== Next Steps ==="
echo "1. Verify the new data directory exists: ls -ld $EPAS17_DATA"
echo "2. If this is a standby/witness, update the same properties on those nodes"
echo "3. Restart EFM: systemctl restart edb-efm-4.8 (or your service name)"
echo "4. Check status: /usr/edb/efm-4.8/bin/efm cluster-status <cluster_name>"