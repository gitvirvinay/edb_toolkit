#!/bin/bash
# ==============================================================================
# Script Name : clean_edb.sh
# Purpose     : Completely remove EPAS (15/17), PEM, and EFM from RHEL systems.
# WARNING     : THIS WILL PERMANENTLY DELETE ALL EDB DATA, CLUSTERS, AND LOGS.
# ==============================================================================

set -e

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run this script as root or with sudo."
  exit 1
fi

echo "====================================================================="
echo " STARTING COMPLETE UNINSTALL OF EPAS, PEM, AND EFM ON RHEL"
echo "====================================================================="

# ------------------------------------------------------------------------------
# STEP 1: STOP AND DISABLE SERVICES
# ------------------------------------------------------------------------------
echo "--> Stopping and disabling EDB services..."

# EPAS Services
systemctl stop edb-as-15 edb-as-17 2>/dev/null || true
systemctl disable edb-as-15 edb-as-17 2>/dev/null || true

# EFM Services (Catches any version like efm-4.x)
for service in $(systemctl list-unit-files | grep -E '^efm-[0-9]' | awk '{print $1}'); do
    systemctl stop "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true
done

# PEM Services
systemctl stop pemagent pem-httpd edb-pem-server 2>/dev/null || true
systemctl disable pemagent pem-httpd edb-pem-server 2>/dev/null || true

# Kill any leftover orphaned processes
echo "--> Terminating any lingering processes..."
pkill -u enterprisedb 2>/dev/null || true
pkill -u efm 2>/dev/null || true
pkill -u pem 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 2: REMOVE RPM PACKAGES
# ------------------------------------------------------------------------------
echo "--> Uninstalling RPM packages via DNF/YUM..."

PKG_MGR="dnf"
if ! command -v dnf &> /dev/null; then
    PKG_MGR="yum"
fi

$PKG_MGR remove -y "edb-as*" "edb-pem*" "edb-efm*" "edb-repo*" 2>/dev/null || true
$PKG_MGR autoremove -y 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 3: DELETE DATA DIRECTORIES, CONFIGS, LOGS, AND SYSTEMD FILES
# ------------------------------------------------------------------------------
echo "--> Deleting data directories, configurations, and logs..."

# Data & Config paths for EPAS, PEM, and EFM
rm -rf /var/lib/edb/
rm -rf /etc/edb/
rm -rf /usr/edb/
rm -rf /var/log/edb/

# EFM specific paths
rm -rf /etc/efm*/
rm -rf /var/log/efm*/
rm -rf /var/efm*/

# PEM specific paths
rm -rf /var/log/pem/
rm -rf /usr/pem/
rm -rf /root/.pem/ /home/*/.pem/

# Systemd custom overrides & lingering unit files
rm -f /etc/systemd/system/edb-as*
rm -f /etc/systemd/system/efm*
rm -f /etc/systemd/system/pem*
rm -f /usr/lib/systemd/system/edb-as*
rm -f /usr/lib/systemd/system/efm*
rm -f /usr/lib/systemd/system/pem*
systemctl daemon-reload

# ------------------------------------------------------------------------------
# STEP 4: REMOVE USERS AND GROUPS
# ------------------------------------------------------------------------------
echo "--> Deleting EDB service accounts and groups..."

userdel -r enterprisedb 2>/dev/null || true
userdel -r efm 2>/dev/null || true
userdel -r pem 2>/dev/null || true

groupdel enterprisedb 2>/dev/null || true
groupdel efm 2>/dev/null || true
groupdel pem 2>/dev/null || true

# ------------------------------------------------------------------------------
# STEP 5: CLEAN UP EDB REPOSITORIES AND CACHE
# ------------------------------------------------------------------------------
echo "--> Cleaning package repositories and metadata cache..."

rm -f /etc/yum.repos.d/edb*.repo
$PKG_MGR clean all
rm -rf /var/cache/dnf /var/cache/yum

# ------------------------------------------------------------------------------
# STEP 6: VERIFICATION
# ------------------------------------------------------------------------------
echo "====================================================================="
echo " UNINSTALLATION COMPLETE — VERIFYING CLEAN STATE"
echo "====================================================================="

echo "[1] Checking for running EDB processes:"
LEFTOVER_PROC=$(ps aux | grep -iE 'edb|post|efm|pem' | grep -v 'grep' | grep -v 'clean_edb.sh' || true)
if [ -z "$LEFTOVER_PROC" ]; then
    echo "    --> No lingering processes found. (PASS)"
else
    echo "    --> WARNING: Found remaining processes:"
    echo "$LEFTOVER_PROC"
fi

echo "[2] Checking for installed EDB packages:"
LEFTOVER_PKG=$(rpm -qa | grep -iE 'edb|efm|pem' || true)
if [ -z "$LEFTOVER_PKG" ]; then
    echo "    --> No packages found. (PASS)"
else
    echo "    --> WARNING: Found remaining RPM packages:"
    echo "$LEFTOVER_PKG"
fi

echo "[3] Checking network ports (5444/5432/8443):"
LEFTOVER_PORTS=$(ss -tulpn | grep -E '5444|5432|8443' || true)
if [ -z "$LEFTOVER_PORTS" ]; then
    echo "    --> All relevant ports are free. (PASS)"
else
    echo "    --> WARNING: Found active bindings on target ports:"
    echo "$LEFTOVER_PORTS"
fi

echo "---------------------------------------------------------------------"
echo "Server is ready for a clean reinstall!"