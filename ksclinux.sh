#!/usr/bin/env bash
# ============================================================================
# 🚀 Install Kaspersky Security Center (KSC) for Linux — One-Click Installer
# 🧩 Kaspersky x VSTECS INDO JAYA
# Created by: Samuel Hamonangan Silitonga (Cyber Security Engineer at Kaspersky)
# ============================================================================
# This script prepares the OS, installs & configures MariaDB for KSC, installs
# KSC Administration Server & Web Console, and shows the access URL.
#
#
# Optional flags:
#   --allow-remote              # Bind MariaDB to 0.0.0.0
#   --open-firewall             # UFW allow 3306/tcp
#   --reduce-priv               # Restrict admin user privileges to kscdb.* after setup
#   --copy-dist-files           # Copy /distr/debian.cnf & /distr/my.cnf if present
#   --admin-user <name>         # Default: kscadmin
#   --admin-pass <password>     # Default: Ka5per$Ky
#   --root-pass  <password>     # Default: Ka5per$Ky
#   --ksc-user <username>       # Default: ksc
#   --ksc-group <groupname>     # Default: kladmins
#
# Notes:
# - This will pause at the Kaspersky postinstall license prompt for manual acceptance.
# - Tested on Ubuntu/Debian-family systems with apt & systemd.
# ============================================================================

set -euo pipefail

# -------------------------------
# Vars (defaults; can be overridden by flags)
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
  if [[ $EUID -ne 0 ]]; then
    err "Run as root (sudo -i)."
    exit 1
  fi
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { err "Required command not found: $c"; exit 1; }
  done
}

confirm_file() {
  local f="$1"
  [[ -f "$f" ]] || { err "File not found: $f"; exit 1; }
}

sql_escape() {
  local s=${1//\'/\'\'}
  printf "%s" "$s"
}

# -------------------------------
# Parse flags
# -------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-remote)   ALLOW_REMOTE="yes"; shift ;;
    --open-firewall)  OPEN_FIREWALL="yes"; shift ;;
    --reduce-priv)    REDUCE_PRIV="yes"; shift ;;
    --copy-dist-files) COPY_DIST_FILES="yes"; shift ;;
    --admin-user)     ADMIN_USER="${2:-}"; shift 2 ;;
    --admin-pass)     ADMIN_PASS="${2:-}"; shift 2 ;;
    --root-pass)      ROOT_PASS="${2:-}"; shift 2 ;;
    --ksc-user)       KSC_USER="${2:-}"; shift 2 ;;
    --ksc-group)      KSC_GROUP="${2:-}"; shift 2 ;;
    --ksc-deb)        KSC_DEB="${2:-}"; shift 2 ;;
    --web-deb)        WEB_DEB="${2:-}"; shift 2 ;;
    --web-json)       WEB_JSON="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '1,120p' "$0"
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# -------------------------------
# Pre-flight
# -------------------------------
require_root
require_cmd apt-get systemctl awk sed grep tee

if [[ -z "${KSC_DEB}" || -z "${WEB_DEB}" || -z "${WEB_JSON}" ]]; then
  err "Missing required args. Provide --ksc-deb, --web-deb, and --web-json."
  exit 1
fi
confirm_file "$KSC_DEB"
confirm_file "$WEB_DEB"
confirm_file "$WEB_JSON"

# -------------------------------
# Pretty banners
# -------------------------------
banner() {
cat <<'EOF'

=============================================================================
🚀 Install Kaspersky Security Center Linux — Kaspersky x VSTECS INDO JAYA
=============================================================================

EOF
}

section() {
  local title="$1"; shift || true
  echo ""
  echo "======================================================================"
  echo "🔸 $title"
  echo "======================================================================"
}

# -------------------------------
# Step 1: System prep
# -------------------------------
system_prep() {
  section "Prepare the system"
  log "Updating packages... ⏳"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || warn "Upgrade had non-fatal issues."

  log "Ensuring user/group for KSC... 👤"
  if ! getent group "$KSC_GROUP" >/dev/null; then
    groupadd "$KSC_GROUP"
    log "Created group: $KSC_GROUP"
  fi
  if ! id "$KSC_USER" >/dev/null 2>&1; then
    useradd -m -g "$KSC_GROUP" "$KSC_USER"
    log "Created user: $KSC_USER (primary group: $KSC_GROUP)"
    warn "Set a secure password for $KSC_USER (recommended):"
    echo "  passwd $KSC_USER"
  else
    log "User $KSC_USER already exists."
  fi

  log "Configuring file limits for $KSC_USER... 📈"
  local lc="/etc/security/limits.conf"
  if ! grep -qE "^$KSC_USER\s+soft\s+nofile\s+32768" "$lc" 2>/dev/null; then
    echo "$KSC_USER soft nofile 32768" | tee -a "$lc" >/dev/null
  fi
  if ! grep -qE "^$KSC_USER\s+hard\s+nofile\s+131072" "$lc" 2>/dev/null; then
    echo "$KSC_USER hard nofile 131072" | tee -a "$lc" >/dev/null
  fi
  log "Limits configured."
}

# -------------------------------
# Step 2: MariaDB install & configure
# -------------------------------
install_mariadb() {
  section "Install & configure MariaDB"
  log "Installing MariaDB server... 💾"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server
  log "Enabling and starting mariadb service..."
  systemctl enable --now mariadb
  systemctl --no-pager status mariadb || true
}

copy_dist_files() {
  [[ "$COPY_DIST_FILES" != "yes" ]] && return 0
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -f /distr/debian.cnf ]]; then
    log "Copying /distr/debian.cnf -> /etc/mysql/ (with backup if exists)"
    [[ -f /etc/mysql/debian.cnf ]] && cp -a /etc/mysql/debian.cnf "/etc/mysql/debian.cnf.bak.$ts"
    cp -f /distr/debian.cnf /etc/mysql/debian.cnf
    chmod 640 /etc/mysql/debian.cnf || true
  else
    warn "/distr/debian.cnf not found; skip."
  fi

  if [[ -f /distr/my.cnf ]]; then
    log "Copying /distr/my.cnf -> /etc/ (with backup if exists)"
    [[ -f /etc/my.cnf ]] && cp -a /etc/my.cnf "/etc/my.cnf.bak.$ts"
    cp -f /distr/my.cnf /etc/my.cnf
  else
    warn "/distr/my.cnf not found; skip."
  fi
}

configure_bind_address() {
  if [[ "$ALLOW_REMOTE" != "yes" ]]; then
    warn "Remote access disabled (use --allow-remote to enable)."
    return 0
  fi
  local server_cnf="/etc/mysql/mariadb.conf.d/50-server.cnf"
  if [[ -f "$server_cnf" ]]; then
    log "Setting bind-address = 0.0.0.0 in $server_cnf 🌐"
    if grep -qE '^\s*bind-address' "$server_cnf"; then
      sed -i 's/^\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$server_cnf"
    else
      awk '
        /^\[mysqld\]/ && !x {print; print "bind-address = 0.0.0.0"; x=1; next}1
      ' "$server_cnf" > "${server_cnf}.tmp" && mv "${server_cnf}.tmp" "$server_cnf"
    fi
  else
    warn "$server_cnf not found; skipping bind-address."
  fi
}

restart_mariadb() {
  log "Restarting MariaDB... 🔁"
  systemctl restart mariadb
  systemctl --no-pager status mariadb || true
}

configure_users() {
  log "Configuring MariaDB users & database... 👮"
  local rpass_sql apass_sql
  rpass_sql=$(sql_escape "$ROOT_PASS")
  apass_sql=$(sql_escape "$ADMIN_PASS")

  mysql --protocol=socket -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${rpass_sql}';
FLUSH PRIVILEGES;
SQL

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

DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
SQL
}

test_login() {
  log "Testing TCP login as ${ADMIN_USER}... 🔌"
  if mysql -u "${ADMIN_USER}" -p"${ADMIN_PASS}" -h 127.0.0.1 -P 3306 -e "SELECT VERSION();" >/dev/null 2>&1; then
    log "Login ${ADMIN_USER} OK (TCP)."
  else
    err "Failed to login as ${ADMIN_USER} via TCP. Check password/host/grants."
    exit 1
  fi
}

open_firewall() {
  [[ "$OPEN_FIREWALL" != "yes" ]] && return 0
  if command -v ufw >/dev/null 2>&1; then
    log "Opening 3306/tcp in ufw... 🔓"
    ufw allow 3306/tcp || warn "Cannot open ufw port (ok if ufw unused)."
  else
    warn "ufw not found; skipping firewall open."
  fi
}

reduce_privileges_if_requested() {
  [[ "$REDUCE_PRIV" != "yes" ]] && return 0
  log "Reducing ${ADMIN_USER} privileges to kscdb.* only... 🔐"
  mysql -u root -p"${ROOT_PASS}" <<SQL
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ADMIN_USER}'@'localhost';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ADMIN_USER}'@'127.0.0.1';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ADMIN_USER}'@'%';

GRANT ALL PRIVILEGES ON kscdb.* TO '${ADMIN_USER}'@'localhost';
GRANT ALL PRIVILEGES ON kscdb.* TO '${ADMIN_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON kscdb.* TO '${ADMIN_USER}'@'%';
FLUSH PRIVILEGES;
SQL
}

summary_db() {
cat <<EOF

=== ✅ MariaDB Summary ===
- MariaDB installed & active.
- root@localhost password set.
- DB: kscdb
- Admin user: ${ADMIN_USER}
- Remote access: ${ALLOW_REMOTE}
- Firewall 3306 opened: ${OPEN_FIREWALL}
- Reduce privilege after install: ${REDUCE_PRIV}

Tips:
- Re-run KSC postinstall if needed:
  /opt/kaspersky/ksc64/bin/setup/postinstall.pl
- Logs:
  journalctl -xeu mariadb
EOF
}

# -------------------------------
# Step 3: Install KSC Admin Server
# -------------------------------
install_ksc_server() {
  section "Install Kaspersky Security Center Linux"
  log "Installing KSC Admin Server from: $KSC_DEB 💿"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$KSC_DEB"
  log "Starting KSC postinstall (interactive EULA)... 📜"
  echo "👉 Please read and accept the License Agreement and Privacy Policy in the upcoming prompt."
  echo "   (This step is interactive and requires manual confirmation.)"
  /opt/kaspersky/ksc64/lib/bin/setup/postinstall.pl || true

  log "Checking KSC services status... 🩺"
  systemctl status --no-pager kladminserver_srv.service klwebsrv_srv.service || true
}

# -------------------------------
# Step 4: Install Web Console
# -------------------------------
install_web_console() {
  section "Install Kaspersky Security Center Web Console"
  log "Copying web console JSON config -> /etc... 🧾"
  cp -f "$WEB_JSON" /etc/ksc-web-console-setup.json
  cat /etc/ksc-web-console-setup.json || true

  log "Installing KSC Web Console from: $WEB_DEB 🌐"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$WEB_DEB"

  log "Restarting KSC services... 🔁"
  systemctl restart kladminserver_srv.service klwebsrv_srv.service
}

# -------------------------------
# Step 5: Final message
# -------------------------------
final_message() {
cat <<'EOF'

======================================================================
🎉 Installation Complete!
======================================================================
🌍 Open the Kaspersky Security Center Web Console in your browser:
➡️  https://ksc:8080
   or
➡️  https://<your_server_ip>:8080

If the page doesn't load yet, give the services a few seconds and refresh.
EOF
}

# -------------------------------
# Main
# -------------------------------
main() {
  banner
  system_prep
  install_mariadb
  copy_dist_files
  configure_bind_address
  restart_mariadb
  configure_users
  test_login
  open_firewall
  reduce_privileges_if_requested
  summary_db
  install_ksc_server
  install_web_console
  final_message
}

main "$@"
