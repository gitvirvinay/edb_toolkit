#!/bin/bash
# ==============================================================================
# Script Name: efm-rolling-upgrade.sh
# Description: EFM Bare-Metal Rolling Upgrade Script with Explicit Java 11
#              Compliance, VIP Node Detection, and Configuration Migration.
# Usage:       sudo ./efm-rolling-upgrade.sh <cluster_name> <old_ver> <new_ver> [vip]
# sudo ./efm-rolling-upgrade.sh billing_cluster 4.7 5.3 192.168.10.50
# ==============================================================================

set -euo pipefail

CLUSTER_NAME="${1:-}"
OLD_VER="${2:-}"
NEW_VER="${3:-}"
CLUSTER_VIP="${4:-}" 

PURGE_OLD_JAVA="false"

# --- Infrastructure & Privileges Validation ---
if [[ -z "${CLUSTER_NAME}" || -z "${OLD_VER}" || -z "${NEW_VER}" ]]; then
    echo "ERROR: Missing required arguments." >&2
    echo "Usage: sudo $0 <cluster_name> <old_version> <new_version> [cluster_vip]" >&2
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be executed with root/sudo privileges." >&2
    exit 1
fi

echo "=== [1/7] Enforcing Java 11 Compliance ==="

# 1. Distro Package Management
if command -v dnf &> /dev/null; then
    echo "Installing Java 11 via DNF..."
    dnf install -y java-11-openjdk-devel
    if [[ "${PURGE_OLD_JAVA}" == "true" ]]; then
        echo "Purging legacy Java packages (Java 1.8/8)..."
        dnf remove -y java-1.8.0-openjdk* || true
    fi
elif command -v apt-get &> /dev/null; then
    echo "Installing Java 11 via APT..."
    apt-get update && apt-get install -y openjdk-11-jdk
    if [[ "${PURGE_OLD_JAVA}" == "true" ]]; then
        echo "Purging legacy Java packages (Java 8)..."
        apt-get purge -y openjdk-8* || true
        apt-get autoremove -y
    fi
else
    echo "ERROR: Unsupported package manager." >&2
    exit 1
fi

# 2. Locate Java 11 Location
JAVA11_BIN=""
for path in /usr/lib/jvm/java-11-openjdk* /usr/lib/jvm/java-11/bin/java /usr/bin/java; do
    if [[ -x "$path/bin/java" ]]; then
        JAVA11_BIN="$path/bin/java"
        break
    elif [[ -x "$path" && "$path" == *"java-11"* ]]; then
        JAVA11_BIN="$path"
        break
    fi
done

if [[ -z "${JAVA11_BIN}" ]]; then
    JAVA11_BIN=$(command -v java)
fi

JAVA_VER=$("${JAVA11_BIN}" -version 2>&1 | head -n 1 | awk -F '"' '{print $2}' | awk -F '.' '{print $1}')
if [ "${JAVA_VER}" -lt 11 ]; then
    echo "ERROR: Could not verify Java 11 installation. Found version: ${JAVA_VER}" >&2
    exit 1
fi
echo "Java 11 verified successfully at: ${JAVA11_BIN}"


echo "=== [2/7] Installing EFM ${NEW_VER} Binaries ==="
NEW_PKG_SUFFIX=$(echo "${NEW_VER}" | tr -d '.')

if command -v dnf &> /dev/null; then
    dnf install -y "edb-efm${NEW_PKG_SUFFIX}"
elif command -v apt-get &> /dev/null; then
    apt-get install -y "edb-efm${NEW_PKG_SUFFIX}"
fi


echo "=== [3/7] Network Interface & VIP Verification ==="
ACTIVE_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [[ -z "${ACTIVE_IFACE}" ]]; then
    echo "ERROR: Could not automatically detect active network interface." >&2
    exit 1
fi
echo "Primary active interface detected: ${ACTIVE_IFACE}"

if [[ -n "${CLUSTER_VIP}" ]]; then
    if ip addr show dev "${ACTIVE_IFACE}" | grep -q "${CLUSTER_VIP}"; then
        echo "👉 WARNING: This node holds the cluster VIP (${CLUSTER_VIP}). This is the PRIMARY node."
        echo "   Ensure Standby and Witness nodes have been upgraded first!"
    else
        echo "ℹ️ NOTICE: This node does not hold the VIP. Safe to proceed as Standby/Witness."
    fi
else
    echo "ℹ️ NOTICE: No cluster VIP provided. Skipping VIP allocation checks."
fi


echo "=== [4/7] Migrating Configuration Files ==="
BACKUP_DIR="/tmp/efm-${OLD_VER}_backup_$(date +%F_%H%M%S)"
echo "Creating emergency configuration backup in ${BACKUP_DIR}..."
cp -rp "/etc/edb/efm-${OLD_VER}" "${BACKUP_DIR}"

# Run EFM built-in upgrade-conf tool
"/usr/edb/efm-${NEW_VER}/bin/efm" upgrade-conf "${CLUSTER_NAME}"

NEW_PROP_FILE="/etc/edb/efm-${NEW_VER}/${CLUSTER_NAME}.properties"
if [[ -f "${NEW_PROP_FILE}" ]]; then
    if [[ -n "${CLUSTER_VIP}" ]]; then
        sed -i "s/^virtual.ip.interface=.*/virtual.ip.interface=${ACTIVE_IFACE}/" "${NEW_PROP_FILE}"
    fi
    
    JAVA_HOME_DIR=$(dirname "$(dirname "${JAVA11_BIN}")")
    sed -i "s|^#\? \?java.home=.*|java.home=${JAVA_HOME_DIR}|" "${NEW_PROP_FILE}"
    chown -R efm:efm "/etc/edb/efm-${NEW_VER}"
    echo "Properties updated and ownership set to efm:efm."
else
    echo "ERROR: Target configuration file ${NEW_PROP_FILE} was not created." >&2
    exit 1
fi

if [[ -d "/etc/edb/efm-${OLD_VER}/script" ]]; then
    cp -rp "/etc/edb/efm-${OLD_VER}/script" "/etc/edb/efm-${NEW_VER}/"
fi


echo "=== [5/7] Stopping EFM ${OLD_VER} Service ==="
OLD_SERVICE="efm-${OLD_VER}"
if [[ "${CLUSTER_NAME}" != "efm" && -f "/etc/systemd/system/efm-${OLD_VER}-${CLUSTER_NAME}.service" ]]; then
    OLD_SERVICE="efm-${OLD_VER}-${CLUSTER_NAME}"
fi

if systemctl is-active --quiet "${OLD_SERVICE}"; then
    systemctl stop "${OLD_SERVICE}"
    echo "Stopped ${OLD_SERVICE}"
fi


echo "=== [6/7] Configuring and Starting EFM ${NEW_VER} ==="
NEW_SERVICE="efm-${NEW_VER}"
if [[ "${CLUSTER_NAME}" != "efm" ]]; then
    NEW_SERVICE="efm-${NEW_VER}-${CLUSTER_NAME}"
    ln -sf "/lib/systemd/system/efm-${NEW_VER}.service" "/etc/systemd/system/${NEW_SERVICE}.service"
fi

if [[ -f "/lib/systemd/system/efm-${NEW_VER}.service" ]]; then
    sed -i "/^Environment=JAVA_HOME=/c\Environment=JAVA_HOME=${JAVA_HOME_DIR}" "/lib/systemd/system/efm-${NEW_VER}.service" || true
fi

systemctl daemon-reload
systemctl enable "${NEW_SERVICE}"
systemctl start "${NEW_SERVICE}"


echo "=== [7/7] Verifying Cluster Status ==="
sleep 10
"/usr/edb/efm-${NEW_VER}/bin/efm" cluster-status "${CLUSTER_NAME}"

echo "==============================================================================="
echo " SUCCESS: EFM rolling upgrade completed successfully on this node."
echo "==============================================================================="