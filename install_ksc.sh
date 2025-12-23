#!/bin/bash
set -euo pipefail

SERVER_IP="IP_PUBLIC_SERVER"

KSC_DEB="ksc64_15.4.0-8873_amd64.deb"
WEB_DEB="ksc-web-console-15.4.1021.x86_64.deb"
WEB_JSON="ksc-web-console-setup.json"

echo "== Preflight: ensure running as root =="
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERR] Run as root: sudo -i"
  exit 1
fi

echo "== Installing prerequisites (download tools + MariaDB client) =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

apt-get install -y \
  wget ca-certificates curl gnupg \
  gawk sed grep coreutils \
  systemd mariadb-client

echo "== Downloading required files =="
wget -O "${KSC_DEB}"  "http://${SERVER_IP}/${KSC_DEB}"
wget -O "${WEB_DEB}"  "http://${SERVER_IP}/${WEB_DEB}"
wget -O "${WEB_JSON}" "http://${SERVER_IP}/${WEB_JSON}"

echo "== Setting execute permission for ksclinux.sh =="
chmod +x ksclinux.sh

echo "== Running ksclinux installer =="
./ksclinux.sh \
  --ksc-deb "${KSC_DEB}" \
  --web-deb "${WEB_DEB}" \
  --web-json "${WEB_JSON}"

echo "== Installation finished =="
