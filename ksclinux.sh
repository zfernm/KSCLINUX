#!/usr/bin/env bash
# =============================================================================
#  Kaspersky Security Center for Linux — Official Installer
# -----------------------------------------------------------------------------
#  Vendor      : Kaspersky
#  Integrator  : VSTECS INDO JAYA
#  Author      : Samuel Hamonangan Silitonga
#  Version     : 1.0.0
#  Tested OS   : Ubuntu 20.04 / 22.04
# =============================================================================

set -Eeuo pipefail
trap 'echo "[FATAL] Error at line $LINENO"; exit 1' ERR

LOG_FILE="/var/log/ksc-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# -----------------------------------------------------------------------------
# Defaults (override via flags)
# -----------------------------------------------------------------------------
KSC_USER="ksc"
KSC_GROUP="kladmins"

DB_NAME="kscdb"
DB_ADMIN="kscadmin"
DB_ADMIN_PASS="KSCdb#Prod01"
DB_ROOT_PASS="KSCdb#Prod01"

ALLOW_REMOTE_DB="no"
OPEN_FIREWALL="no"
REDUCE_DB_PRIV="yes"

KSC_DEB=""
WEB_DEB=""
WEB_JSON=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[FATAL]\033[0m $*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (sudo -i)"
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ksc-deb)  KSC_DEB="$2"; shift 2 ;;
    --web-deb)  WEB_DEB="$2"; shift 2 ;;
    --web-json) WEB_JSON="$2"; shift 2 ;;
    --allow-remote-db) ALLOW_REMOTE_DB="yes"; shift ;;
    --open-firewall)   OPEN_FIREWALL="yes"; shift ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ -f "$KSC_DEB" ]]  || die "Missing KSC DEB"
[[ -f "$WEB_DEB" ]]  || die "Missing Web Console DEB"
[[ -f "$WEB_JSON" ]] || die "Missing Web Console JSON"

# -----------------------------------------------------------------------------
# System preparation
# -----------------------------------------------------------------------------
require_root
info "Preparing system..."
apt-get update -y
apt-get install -y mariadb-server ufw

info "Ensuring KSC user & group..."
getent group "$KSC_GROUP" >/dev/null || groupadd "$KSC_GROUP"
id "$KSC_USER" >/dev/null 2>&1 || useradd -m -g "$KSC_GROUP" "$KSC_USER"

usermod -g "$KSC_GROUP" "$KSC_USER"
usermod -aG "$KSC_GROUP" "$KSC_USER"

# -----------------------------------------------------------------------------
# MariaDB configuration
# -----------------------------------------------------------------------------
info "Configuring MariaDB..."
systemctl enable --now mariadb

mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
CREATE DATABASE IF NOT EXISTS $DB_NAME
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_ADMIN'@'%' IDENTIFIED BY '$DB_ADMIN_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_ADMIN'@'%';
FLUSH PRIVILEGES;
SQL

# -----------------------------------------------------------------------------
# Install KSC
# -----------------------------------------------------------------------------
info "Installing Kaspersky Security Center..."
apt-get install -y "$KSC_DEB"

/opt/kaspersky/ksc64/lib/bin/setup/postinstall.pl

# -----------------------------------------------------------------------------
# Install Web Console
# -----------------------------------------------------------------------------
info "Installing Web Console..."
cp "$WEB_JSON" /etc/ksc-web-console-setup.json
apt-get install -y "$WEB_DEB"

systemctl restart kladminserver_srv.service klwebsrv_srv.service

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------
if [[ "$OPEN_FIREWALL" == "yes" ]]; then
  ufw allow 13000,14000,8080/tcp
fi

# -----------------------------------------------------------------------------
# Final check
# -----------------------------------------------------------------------------
info "Validating services..."
systemctl --no-pager status kladminserver_srv.service || true

cat <<EOF

====================================================================
✅ Kaspersky Security Center installation completed
====================================================================
🌐 Web Console:
  https://$(hostname -I | awk '{print $1}'):8080

📄 Log file:
  $LOG_FILE
====================================================================

EOF
