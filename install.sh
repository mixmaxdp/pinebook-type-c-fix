#!/bin/bash
# Install USB-C Host Detector for Pinebook Pro
set -e

REPO="$(cd "$(dirname "$0")" && pwd)"
BUILD="/tmp/typec-force-host-install"
MODULE_DEST="/usr/local/lib/typec-force-host"

echo "== Preparing build directory =="
mkdir -p "$BUILD"
cp "$REPO/typec_force_host.c" "$BUILD/"
cp "$REPO/Makefile" "$BUILD/"

echo "== Building kernel module =="
cd "$BUILD"
make clean 2>/dev/null || true
make

echo "== Installing files =="
install -d "$MODULE_DEST"
install -m 644 "$BUILD/typec_force_host.ko" "$MODULE_DEST/"
install -m 755 "$REPO/typec-host-detector.sh" /usr/local/lib/
install -m 644 "$REPO/typec-host-detector.service" /etc/systemd/system/

echo "== Restarting service =="
rmmod typec_force_host 2>/dev/null || true
systemctl daemon-reload
systemctl enable typec-host-detector.service 2>/dev/null || true
systemctl restart typec-host-detector.service

echo "== Done =="
echo ""
echo "Service status:"
systemctl status typec-host-detector.service --no-pager 2>&1 | head -10
echo ""
echo "Check logs: journalctl -u typec-host-detector -f"
