#!/bin/bash

set -e

SERVER_IP="IP_PUBLIC_SERVER"

echo "== Downloading required files =="

wget http://${SERVER_IP}/ksc64_15.4.0-8873_amd64.deb
wget http://${SERVER_IP}/ksc-web-console-15.4.1021.x86_64.deb
wget http://${SERVER_IP}/ksc-web-console-setup.json

echo "== Setting execute permission for ksclinux.sh =="
chmod +x ksclinux.sh

echo "== Running ksclinux installer =="

./ksclinux.sh \
  --ksc-deb ksc64_15.4.0-8873_amd64.deb \
  --web-deb ksc-web-console-15.4.1021.x86_64.deb \
  --web-json ksc-web-console-setup.json

echo "== Installation finished =="
