#!/bin/bash
echo ""
echo "=================================================="
echo " Debian rootfs is alive (switch_root succeeded)"
cat /etc/os-release
echo "=================================================="
echo ""
i=0
while true; do
	i=$((i + 1))
	echo "[debian] alive, uptime tick $i"
	sleep 15
done
