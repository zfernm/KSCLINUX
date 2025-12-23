#!/usr/bin/env bash
# ============================================================================
# 🚀 Install Kaspersky Security Center (KSC) for Linux — One-Click Installer
# 🧩 Kaspersky x VSTECS INDO JAYA
# Created by: Samuel Hamonangan Silitonga
# Maintained & Hardened version (VM-ready)
# ============================================================================
# Notes:
# - SAFE DB PASSWORD (avoid: $, ', ", `) -> default: KSCdb#Prod01
# - Uses local .deb install via "./file.deb" (IMPORTANT)
# - Tested for device scale option 1 / 2 / 3 (EULA step is interactive)
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
  # Escape single quotes for SQL strings
  printf "%s" "${1//\'/\'\'}"
}

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
# Parse flags
# -------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-remote) ALLOW_REMOTE="yes"; shift ;;
    --open-firewall) OPEN_FIREWALL="yes"; shift ;;
    --reduce-priv) REDUCE_PRIV="yes"; shift ;;
    --copy-dist-files) COPY_DIST_FILES="yes"; shift ;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
    --admin-pass) ADMIN_PASS="${2:-}"; shift 2 ;;
    --root-pass)  ROOT_PASS="${2:-}"; shift 2 ;;
    --ksc-user)   KSC_USER="${2:-}"; shift 2 ;;
    --ksc-group)  KSC_GROUP="${2:-}"; shift 2 ;;
    --ksc-deb)    KSC_DEB="${2:-}"; shift 2 ;;
    --web-deb)    WEB_DEB="${2:-}"; shift 2 ;;
    --web-json)   WEB_JSON="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '1,200p' "$0"
      exit 0
      ;;
    *)
      err "Unknown arg: $1"
      exit 1
      ;;
  esac
done

# -------------------------------
# Pre-flight
# -------------------------------
require_root
require_cmd apt-get systemctl awk sed grep tee

[[ -n "$KSC_DEB" && -n "$WEB_DEB" && -n "$WEB_JSON" ]] || {
  err "Missing --ksc-deb / --web-deb / --web-json"
  exit 1
}

confirm_file "$KSC_DEB"
confirm_file "$WEB_DEB"
confirm_file "$WEB_JSON"

# Important: ensure we install local debs with ./ prefix
KSC_DEB_PATH="$KSC_DEB"
WEB_DEB_PATH="$WEB_DEB"
[[ "$KSC_DEB_PATH" == ./* ]] || KSC_DEB_PATH="./$KSC_DEB_PATH"
[[ "$WEB_DEB_PATH" == ./* ]] || WEB_DEB_PATH="./$WEB_DEB_PATH"

# -------------------------------
# System Prep
# -------------------------------
system_prep() {
  section "System preparation"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y || true

  log "Ensuring group/user..."
  getent group "$KSC_GROUP" >/dev/null || groupadd "$KSC_GROUP"
  id "$KSC_USER" >/dev/null 2>&1 || useradd -m -g "$KSC_GROUP" "$KSC_USER"

  log "Configuring file limits (idempotent)..."
  local lc="/etc/security/limits.conf"
  grep -qE "^${KSC_USER}\s+soft\s+nofile\s+32768" "$lc" 2>/dev/null || echo "${KSC_USER} soft nofile 32768" | tee -a "$lc" >/dev/null
  grep -qE "^${KSC_USER}\s+hard\s+nofile\s+131072" "$lc" 2>/dev/null || echo "${KSC_USER} hard nofile 131072" | tee -a "$lc" >/dev/null
}

# -------------------------------
# MariaDB
# -------------------------------
install_mariadb() {
  section "Install MariaDB"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y mariadb-server mariadb-client

  systemctl enable --now mariadb
}

configure_bind_address() {
  [[ "$ALLOW_REMOTE" == "yes" ]] || { warn "Remote MariaDB disabled (use --allow-remote to enable)."; return 0; }

  section "Configure MariaDB bind-address (0.0.0.0)"
  local server_cnf="/etc/mysql/mariadb.conf.d/50-server.cnf"

  if [[ ! -f "$server_cnf" ]]; then
    warn "File not found: $server_cnf (skip bind-address)"
    return 0
  fi

  if grep -qE '^\s*bind-address\s*=' "$server_cnf"; then
    sed -i 's/^\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$server_cnf"
  else
    # Insert under [mysqld]
    awk '
      BEGIN{done=0}
      /^\[mysqld\]/{print; if(!done){print "bind-address = 0.0.0.0"; done=1; next}}
      {print}
      END{if(!done){print "[mysqld]"; print "bind-address = 0.0.0.0"}}
    ' "$server_cnf" > "${server_cnf}.tmp" && mv "${server_cnf}.tmp" "$server_cnf"
  fi

  systemctl restart mariadb
}

configure_users() {
  section "Configure MariaDB users"

  # Escape for SQL
  local rpass_sql apass_sql
  rpass_sql="$(sql_escape "$ROOT_PASS")"
  apass_sql="$(sql_escape "$ADMIN_PASS")"

  # Ensure root password set (socket login first)
  mysql --protocol=socket -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${rpass_sql}';
FLUSH PRIVILEGES;
SQL

  # Create DB + admin accounts
  mysql -u root -p"${ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS kscdb
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'localhost' IDENTIFIED BY '${apass_sql}';
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${apass_sql}';
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'%' IDENTIFIED BY '${apass_sql}';

ALTER USER '${ADMIN_USER}'@'localhost' IDENTIFIED BY '${apass_sql}';
ALTER USER '${ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${apass_sql}';
ALTER USER '${ADMIN_USER}'@'%' IDENTIFIED BY '${apass_sql}';

GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL

  if [[ "$REDUCE_PRIV" == "yes" ]]; then
    section "Reduce DB privileges (kscdb.* only)"
    mysql -u root -p"${ROOT_PASS}" <<SQL
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ADMIN_USER}'@'localhost';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ADMIN_USER}'@'127.0.0.1';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ADMIN_USER}'@'%';

GRANT ALL PRIVILEGES ON kscdb.* TO '${ADMIN_USER}'@'localhost';
GRANT ALL PRIVILEGES ON kscdb.* TO '${ADMIN_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON kscdb.* TO '${ADMIN_USER}'@'%';

FLUSH PRIVILEGES;
SQL
  fi
}

test_login() {
  section "Test DB login"
  mysql -u "${ADMIN_USER}" -p"${ADMIN_PASS}" -h 127.0.0.1 -P 3306 -e "SELECT 1;" \
    || { err "DB login failed"; exit 1; }
}

open_firewall() {
  [[ "$OPEN_FIREWALL" == "yes" ]] || return 0
  section "Open firewall (3306/tcp)"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 3306/tcp || warn "UFW open port failed (ok if UFW not used)."
  else
    warn "ufw not found; skipping."
  fi
}

# -------------------------------
# KSC Install
# -------------------------------
install_ksc() {
  section "Install KSC Administration Server (local .deb)"
  export DEBIAN_FRONTEND=noninteractive

  # Install local deb (IMPORTANT: ./file.deb)
  apt-get update -y
  apt-get install -y "$KSC_DEB_PATH"

  log "Starting KSC postinstall (interactive EULA/Privacy prompt)..."
  /opt/kaspersky/ksc64/lib/bin/setup/postinstall.pl

  log "KSC services (may vary by version):"
  systemctl status --no-pager kladminserver_srv.service klwebsrv_srv.service || true
}

install_web() {
  section "Install Web Console (local .deb)"

  cp -f "$WEB_JSON" /etc/ksc-web-console-setup.json

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$WEB_DEB_PATH"

  systemctl restart kladminserver_srv.service klwebsrv_srv.service || true
}

# -------------------------------
# Finish
# -------------------------------
finish() {
cat <<EOF

======================================================================
🎉 INSTALLATION COMPLETE
======================================================================

Web Console:
  https://<server-ip>:8080

DB:
  User     : ${ADMIN_USER}
  Password : ${ADMIN_PASS}
  DB Name  : kscdb

Notes:
- If browser can't open immediately, wait ~30s and refresh.
- If postinstall needs rerun:
  /opt/kaspersky/ksc64/bin/setup/postinstall.pl

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
open_firewall
install_ksc
install_web
finish
