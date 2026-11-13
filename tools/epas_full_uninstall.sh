#!/usr/bin/env bash
# =============================================================================
# tools/epas_full_uninstall.sh - remove EPAS (15/17), EFM and PEM from a RHEL server
#
#   sudo tools/epas_full_uninstall.sh [--env conf/site.env] [--yes]
#
# WARNING: removes every EDB package, service and OS user, and deletes /var/lib/edb,
# /etc/edb, /usr/edb, /var/log/edb and the EFM and PEM equivalents. It cannot be undone.
# Run it as root (sudo). On a terminal it asks you to type the host name first;
# unattended (cron, Ansible) it refuses unless --yes is given.
#
# It does NOT touch the cluster mounts (DATA_TOP, WAL_TOP, ARCHIVE_TOP, BACKUP_TOP, LOG_TOP)
# or BINARY_TOP: it lists at the end what is left there, to be removed by hand once the
# backups are known to be safe somewhere else.
#
# The run is logged in <LOG_MOUNT>/toolkit, the one log directory this script keeps.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }
parse_common_args "$@"; set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
case "${1:-}" in -h|--help) usage ;; "") ;; *) die "Unknown option: $1 (see --help)" ;; esac
require_root
load_env optional          # a half-installed server may have no site.env; it must still be cleanable

PKG_MGR="dnf"; command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"

log_info "Complete uninstall of EPAS, EFM and PEM on $(hostname -s)"
log_info "EDB packages installed now: $(rpm -qa 2>/dev/null | grep -iE '^(edb|efm|pem)' | tr '\n' ' ')"
confirm_destructive "remove all EDB software, services, OS users and system directories on this host"
log_audit "Uninstall started by $(whoami)"

# ---- 1. Stop and disable services --------------------------------------------------------------
log_info "Step 1: stopping and disabling EDB services"
systemctl stop    edb-as-15 edb-as-17 2>/dev/null || true
systemctl disable edb-as-15 edb-as-17 2>/dev/null || true
for service in $(systemctl list-unit-files 2>/dev/null | awk '/^(edb-)?efm-[0-9]/ {print $1}'); do
    systemctl stop    "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true
done
systemctl stop    pemagent pem-httpd edb-pem-server 2>/dev/null || true
systemctl disable pemagent pem-httpd edb-pem-server 2>/dev/null || true

log_info "Step 1: ending leftover processes of enterprisedb, efm and pem"
for u in enterprisedb efm pem; do pkill -u "$u" 2>/dev/null || true; done

# ---- 2. Remove packages -----------------------------------------------------------------------
log_info "Step 2: removing packages with ${PKG_MGR}"
$PKG_MGR remove -y "edb-as*" "edb-pem*" "edb-efm*" "edb-repo*" 2>/dev/null || true
$PKG_MGR autoremove -y 2>/dev/null || true

# ---- 3. Delete system directories and unit files ----------------------------------------------
log_info "Step 3: deleting EDB system directories (/var/lib/edb /etc/edb /usr/edb /var/log/edb, EFM, PEM)"
rm -rf /var/lib/edb/ /etc/edb/ /usr/edb/ /var/log/edb/
rm -rf /etc/efm*/ /var/log/efm*/ /var/efm*/
rm -rf /var/log/pem/ /usr/pem/ /root/.pem/ /home/*/.pem/
rm -f  /etc/systemd/system/edb-as*     /etc/systemd/system/efm*     /etc/systemd/system/pem*
rm -f  /usr/lib/systemd/system/edb-as* /usr/lib/systemd/system/efm* /usr/lib/systemd/system/pem*
systemctl daemon-reload

# ---- 4. Remove OS users and groups ------------------------------------------------------------
log_info "Step 4: removing OS users and groups enterprisedb, efm, pem"
for u in enterprisedb efm pem; do userdel -r "$u" 2>/dev/null || true; done
for g in enterprisedb efm pem; do groupdel  "$g" 2>/dev/null || true; done

# ---- 5. Repositories and cache ---------------------------------------------------------------
log_info "Step 5: removing EDB repositories and package cache"
rm -f /etc/yum.repos.d/edb*.repo
$PKG_MGR clean all >/dev/null 2>&1 || true
rm -rf /var/cache/dnf /var/cache/yum

# ---- 6. Verify --------------------------------------------------------------------------------
log_info "Step 6: verifying"
left=$(ps -eo user:20,pid,comm | awk 'NR>1 && ($1 ~ /^(enterprisedb|efm|pem)$/ || $3 ~ /^(edb-|efm|pemagent|postgres|postmaster|edb-postgres)/)' || true)
if [ -z "$left" ]; then log_info "  processes: none left (PASS)"
else log_warn "  processes still running:"; log_warn "$left"; fi

left=$(rpm -qa 2>/dev/null | grep -iE '^(edb|efm|pem)' || true)
if [ -z "$left" ]; then log_info "  packages: none left (PASS)"
else log_warn "  packages still installed: $(echo "$left" | tr '\n' ' ')"; fi

left=$(ss -tlnp 2>/dev/null | grep -E ':(5444|5432|8443)[[:space:]]' || true)
if [ -z "$left" ]; then log_info "  ports 5444/5432/8443: free (PASS)"
else log_warn "  ports still in use:"; log_warn "$left"; fi

# ---- 7. What this script deliberately left alone ---------------------------------------------
log_info "Left in place (remove by hand once the backups are confirmed safe elsewhere):"
kept=0
for v in DATA_TOP WAL_TOP ARCHIVE_TOP BACKUP_TOP LOG_TOP BINARY_TOP; do
    d="${!v:-}"
    if [ -n "$d" ] && [ -e "$d" ]; then
        log_info "  ${v}=${d}  ($(du -sh "$d" 2>/dev/null | cut -f1 || echo '?'))"; kept=1
    fi
done
[ "$kept" -eq 1 ] || log_info "  nothing found (no site.env, or the directories do not exist)"

log_audit "Uninstall finished on $(hostname -s)"
log_info "Server is ready for a clean reinstall."
