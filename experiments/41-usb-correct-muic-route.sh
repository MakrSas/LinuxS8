#!/bin/sh
# USB bring-up, phase 6: route MAX77865 MUIC to AP USB at its real address.
#
# The MAX77865 parent is at 0x66; vendor code creates its MUIC dummy client at
# (0x4A >> 1) = 0x25.  CONTROL1=0x89 is the vendor COM_USB_AP value.

say() {
	echo "[usb-route] $*"
}

find_bus() {
	pattern="$1"
	for node in /sys/class/i2c-dev/i2c-* /sys/class/i2c-adapter/i2c-*; do
		[ -e "$node" ] || continue
		target="$(readlink -f "$node/device" 2>/dev/null || true)"
		case "$target" in
			*$pattern*) echo "${node##*-}"; return 0 ;;
		esac
	done
	return 1
}

CCIC_BUS="$(find_bus '10950000.i2c' || true)"
MUIC_BUS="$(find_bus '10970000.i2c' || true)"
say "buses: ccic=$CCIC_BUS muic=$MUIC_BUS"

if [ -z "$CCIC_BUS" ] || [ -z "$MUIC_BUS" ]; then
	say "ERROR: required I2C bus is missing"
	exit 1
fi

read_muic() {
	reg="$1"
	value="$(i2ctransfer -y "$MUIC_BUS" w1@0x25 "0x$reg" r1 2>/dev/null || true)"
	say "MUIC reg=0x$reg value=${value:-ERROR}"
}

say "MAX77865 MUIC before route"
read_muic 00
read_muic 13
read_muic 19

ID="$(i2ctransfer -y "$MUIC_BUS" w1@0x25 0x00 r1 2>/dev/null | tr -d '[:space:]\r')"
if [ "$ID" != "0x65" ]; then
	say "ERROR: expected MAX77865 MUIC ID 0x65, got $ID; refusing write"
	exit 1
fi

say "vendor COM_USB_AP: MUIC 0x25 CONTROL1 0x19 <- 0x89"
i2ctransfer -y "$MUIC_BUS" w2@0x25 0x19 0x89 2>&1
say "route write rc=$?"
read_muic 19

say "vendor S2MM005 TYPE_C_ATTACH_UFP: detach 03 12"
i2ctransfer -y "$CCIC_BUS" w4@0x33 0x00 0x10 0x03 0x12 2>&1 || true
sleep 1
say "vendor S2MM005 TYPE_C_ATTACH_UFP: sink/UFP 03 14"
i2ctransfer -y "$CCIC_BUS" w4@0x33 0x00 0x10 0x03 0x14 2>&1 || true
sleep 1

say "force gadget connect via UDC soft_connect"
for udc in /sys/class/udc/*; do
	[ -e "$udc/soft_connect" ] || continue
	say "udc=$(basename "$udc")"
	echo connect > "$udc/soft_connect" 2>&1 || true
done
sleep 8

say "MUIC after route and UFP"
read_muic 19
for udc in /sys/class/udc/*; do
	[ -e "$udc" ] || continue
	say "udc=$(basename "$udc") state=$(cat "$udc/state" 2>/dev/null || true) speed=$(cat "$udc/current_speed" 2>/dev/null || true)"
done
ip -details link show usb0 2>&1 || true
say "correct MUIC USB route experiment finished"
