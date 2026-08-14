#!/bin/sh
# USB bring-up, phase 2: explain why hsi2c_32 is not registering.
# Read-only diagnostics; no I2C transactions and no register writes.

say() {
	echo "[i2c-platform] $*"
}

say "kernel messages for USI13/HSI2C"
dmesg 2>&1 | grep -Ei 'exynos-usi|exynos5-hsi2c|10960000|10970000|hsi2c|i2c' || true

say "platform devices"
for dev in /sys/bus/platform/devices/10960000.i2c \
	/sys/bus/platform/devices/10970000.i2c \
	/sys/bus/platform/devices/soc@0:usi@10960000; do
	[ -e "$dev" ] || continue
	say "$dev"
	readlink -f "$dev" 2>&1 || true
	readlink -f "$dev/driver" 2>&1 || true
	cat "$dev/uevent" 2>&1 || true
done

say "runtime device-tree status"
for node in \
	/sys/firmware/devicetree/base/soc@0/usi@10960000 \
	/sys/firmware/devicetree/base/soc@0/usi@10960000/i2c@0 \
	/sys/firmware/devicetree/base/soc@0/usi@10960000/i2c@10000; do
	[ -e "$node" ] || continue
	say "$node status=$(tr -d '\000' < "$node/status" 2>/dev/null || echo missing)"
done

say "deferred devices"
cat /sys/kernel/debug/devices_deferred 2>&1 || true

say "interrupts 426/427"
grep -E '(^|[[:space:]])(426|427):' /proc/interrupts 2>&1 || true

say "registered I2C adapters"
i2cdetect -l 2>&1 || true

say "platform debug finished"
