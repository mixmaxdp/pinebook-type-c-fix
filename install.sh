#!/bin/bash
# Install USB-C Host Detector for Pinebook Pro
set -e

SRC="/tmp/typec-force-host-install"
DEST_SRC="/home/max/typec-force-host"
MODULE_DEST="/usr/local/lib/typec-force-host"
SCRIPT_DEST="/usr/local/lib"

echo "== Building kernel module =="
cd "$SRC"
make clean 2>/dev/null || true
make

echo "== Installing files =="
install -d "$DEST_SRC"
install -d "$MODULE_DEST"
install -m 644 "$SRC/typec_force_host.c" "$DEST_SRC/"
install -m 644 "$SRC/Makefile" "$DEST_SRC/"
install -m 644 "$SRC/typec_force_host.ko" "$MODULE_DEST/"
install -m 755 "$SRC/typec-host-detector.sh" "$SCRIPT_DEST/"
install -m 644 "$SRC/typec-host-detector.service" /etc/systemd/system/

echo "== Enabling service =="
systemctl daemon-reload
systemctl enable typec-host-detector.service
systemctl start typec-host-detector.service

echo "== Done =="
echo ""
echo "Service status:"
systemctl status typec-host-detector.service --no-pager 2>&1 | head -10
echo ""
echo "The USB-C port will now auto-detect chargers vs devices."
echo "Check logs: journalctl -u typec-host-detector -f"
