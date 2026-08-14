#!/bin/sh
# Load the first mainline S2MM005 driver and collect only its probe/IRQ data.
# The module is intentionally loaded explicitly so a failed probe cannot
# create a boot loop while the driver is still bring-up quality.

say() {
	echo "[s2mm005-kernel] $*"
}

MOD=/root/lab/s2mm005.ko
say "kernel: $(uname -r)"
say "module: $MOD"
say "gpio state before module:"
grep -E 'gpa1|gpi1' /sys/kernel/debug/gpio 2>/dev/null || true

say "insmod"
insmod "$MOD"
say "insmod rc=$?"
sleep 2

say "force gadget connect via UDC soft_connect"
for udc in /sys/class/udc/*; do
	[ -e "$udc/soft_connect" ] || continue
	say "udc=$(basename "$udc") soft_connect=$(ls -l "$udc/soft_connect" 2>/dev/null || true)"
	echo connect > "$udc/soft_connect"
	say "soft_connect rc=$?"
done
sleep 2

say "matching dmesg:"
dmesg | grep -i -E 's2mm005|10950000|i2c-1|usb' | tail -n 100 || true

say "i2c device:"
find /sys/bus/i2c/devices -maxdepth 1 -name '*-0033' -print -exec sh -c 'readlink -f "$1/driver" 2>/dev/null || true' sh {} \;

say "UDC state:"
for udc in /sys/class/udc/*; do
	[ -e "$udc" ] || continue
	say "udc=$udc"
	for field in state current_speed maximum_speed soft_connect; do
		[ -r "$udc/$field" ] && say "$field=$(cat "$udc/$field")"
	done
done
[ -r /sys/kernel/config/usb_gadget/dreamlte/UDC ] && \
	say "configfs UDC=$(cat /sys/kernel/config/usb_gadget/dreamlte/UDC)"
ip -details link show usb0 2>/dev/null || true

say "interrupts:"
grep -i -E 's2mm005|gpa1|i2c|dwc3|10c00000' /proc/interrupts || true

say "gpio state after module:"
grep -E 'gpa1|gpi1' /sys/kernel/debug/gpio 2>/dev/null || true
