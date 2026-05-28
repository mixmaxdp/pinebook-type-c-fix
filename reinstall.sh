#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building module ==="
make clean 2>/dev/null
make

echo "=== Installing ==="
cp typec_force_host.ko /usr/local/lib/typec-force-host/
cp typec_force_host.c /usr/local/lib/typec-force-host/

echo "=== Reloading module ==="
rmmod typec_force_host 2>/dev/null || true
insmod /usr/local/lib/typec-force-host/typec_force_host.ko

echo "=== Restarting detector service ==="
systemctl restart typec-host-detector 2>/dev/null || true

echo "=== Done ==="
echo "dmesg:"
dmesg | grep 'typec_force_host' | tail -3
