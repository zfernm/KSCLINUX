#!/usr/bin/env bash
# ============================================================================
# 🚀 Install Kaspersky Security Center (KSC) for Linux — One-Click Installer
# 🧩 Kaspersky x VSTECS INDO JAYA
# Created by: Samuel Hamonangan Silitonga
# Maintained & Hardened version
# ============================================================================
# Notes:
# - SAFE DB PASSWORD (no $, ', ", `)
# - Tested for device scale option 1 / 2 / 3
# ============================================================================

set -euo pipefail

# -------------------------------
# Vars (defaults)
# -------------------------------
ALLOW_REMOTE="no"
OPEN_FIREWALL="no"
REDUCE_PRIV="no"
COPY_DIST_FILES="no"

ADMIN_USER="kscadmin"
ADMIN_PASS="KSCdb#Prod01"
ROOT_PASS="KSCdb#Prod01"

KSC_USER="ksc"
KSC_GROUP="kladmins"

KSC_DEB=""
WEB_DEB=""
WEB_JSON=""

# -------------------------------
# Helpers
# -------------------------------
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

require_root() {
  [[ $EUID -eq 0 ]] || { err "Run as root (sudo -i)."; exit 1; }
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "Missing command: $c"; exit 1; }
  done
}

confirm_file() {
  [[ -f "$1" ]] || { err "File not found: $1"; exit 1; }
}

sql_escape() {
  printf "%s" "${1//\'/\'\'}"
}

# -------------------------------
# Parse flags
# -------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-remote) ALLOW_REMOTE="yes"; shift ;;
    --open-firewall) OPEN_FIREWALL="yes"; shift ;;
    --reduce-priv) REDUCE_PRIV="yes"; shift ;;
    --copy-dist-files) COPY_DIST_FILES="yes"; shift ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
    --root-pass) ROOT_PASS="$2"; shift 2 ;;
    --ksc-user) KSC_USER="$2"; shift 2 ;;
    --ksc-group) KSC_GROUP="$2"; shift 2 ;;
    --ksc-deb) KSC_DEB="$2"; shift 2 ;;
    --web-deb) WEB_DEB="$2"; shift 2 ;;
    --web-json) WEB_JSON="$2"; shift 2 ;;
    -h|--help) sed -n '1,120p' "$0"; exit 0 ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
done

# -------------------------------
# Pre-flight
# -------------------------------
require_root
require_cmd apt-get systemctl mysql awk sed grep tee

[[ -n "$KSC_DEB" && -n "$WEB_DEB" && -n "$WEB_JSON" ]] || {
  err "Missing --ksc-deb / --web-deb / --web-json"
  exit 1
}

confirm_file "$KSC_DEB"
confirm_file "$WEB_DEB"
confirm_file "$WEB_JSON"

# -------------------------------
# UI
# -------------------------------
banner() {
cat <<'EOF'

=============================================================================
🚀 Kaspersky Security Center Linux Installer
=============================================================================

EOF
}

section() {
  echo -e "\n======================================================================"
  echo "🔸 $1"
  echo "======================================================================"
}

# -------------------------------
# System Prep
# -------------------------------
system_prep() {
  section "System preparation"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || true

  getent group "$KSC_GROUP" >/dev/null || groupadd "$KSC_GROUP"
  id "$KSC_USER" >/dev/null 2>&1 || useradd -m -g "$KSC_GROUP" "$KSC_USER"

  cat <<EOF >> /etc/security/limits.conf
$KSC_USER soft nofile 32768
$KSC_USER hard nofile 131072
EOF
}

# -------------------------------
# MariaDB
# -------------------------------
install_mariadb() {
  section "Install MariaDB"
  apt-get install -y mariadb-server
  systemctl enable --now mariadb
}

configure_bind_address() {
  [[ "$ALLOW_REMOTE" == "yes" ]] || return 0
  sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' \
    /etc/mysql/mariadb.conf.d/50-server.cnf || true
}

configure_users() {
  section "Configure MariaDB users"

  mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}';
FLUSH PRIVILEGES;
SQL

  mysql -u root -p"${ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS kscdb
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'localhost' IDENTIFIED BY '${ADMIN_PASS}';
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${ADMIN_PASS}';
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'%' IDENTIFIED BY '${ADMIN_PASS}';

GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

test_login() {
  section "Test DB login"
  mysql -u "${ADMIN_USER}" -p"${ADMIN_PASS}" -h localhost -e "SELECT 1;" \
    || { err "DB login failed"; exit 1; }
}

# -------------------------------
# KSC Install
# -------------------------------
install_ksc() {
  section "Install KSC Administration Server"
  apt-get install -y "$KSC_DEB"
  /opt/kaspersky/ksc64/lib/bin/setup/postinstall.pl
}

install_web() {
  section "Install Web Console"
  cp -f "$WEB_JSON" /etc/ksc-web-console-setup.json
  apt-get install -y "./$WEB_DEB"
  systemctl restart kladminserver_srv.service klwebsrv_srv.service
}


# -------------------------------
# Finish
# -------------------------------
finish() {
cat <<EOF

🎉 INSTALLATION COMPLETE

Web Console:
https://<server-ip>:8080

DB User     : ${ADMIN_USER}
DB Password : ${ADMIN_PASS}

EOF
}

# -------------------------------
# Main
# -------------------------------
banner
system_prep
install_mariadb
configure_bind_address
configure_users
test_login
install_ksc
install_web
finish
