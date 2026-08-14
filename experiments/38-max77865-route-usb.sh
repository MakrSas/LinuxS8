#!/bin/sh
# USB bring-up, phase 3: source-backed AP USB route for MAX77865.
#
# The vendor tree identifies this chip by ID 0x65.  Its USB/AP switch is
# CONTROL1 at 0x19; COM_USB_AP evaluates to 0x89.  The write is reversible
# (COM_OPEN is 0x80) and is guarded by the ID read below.

say() {
	echo "[max77865-route] $*"
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

read_s2mm005() {
	reg="$1"
	hi="0x${reg%??}"
	lo="0x${reg#??}"
	say "S2MM005 reg 0x$reg:"
	i2ctransfer -y "$CCIC_BUS" "w2@0x33" "$hi" "$lo" r4 2>&1 || true
}

say "S2MM005 before UFP toggle"
read_s2mm005 0020
read_s2mm005 0060

say "vendor S2MM005 TYPE_C_ATTACH_UFP: detach 03 12"
i2ctransfer -y "$CCIC_BUS" w4@0x33 0x00 0x10 0x03 0x12 2>&1 || true
sleep 1
say "vendor S2MM005 TYPE_C_ATTACH_UFP: sink/UFP 03 14"
i2ctransfer -y "$CCIC_BUS" w4@0x33 0x00 0x10 0x03 0x14 2>&1 || true
sleep 1

say "S2MM005 after UFP toggle"
read_s2mm005 0020
read_s2mm005 0060

read_muic() {
	reg="$1"
	say "MAX77865 reg 0x$reg:"
	i2ctransfer -y "$MUIC_BUS" "w1@0x66" "0x$reg" r1 2>&1 || true
}

say "MAX77865 identity and route before write"
read_muic 00
read_muic 13
read_muic 19

ID="$(i2ctransfer -y "$MUIC_BUS" w1@0x66 0x00 r1 2>/dev/null | tr -d '[:space:]\r')"
if [ "$ID" != "0x65" ]; then
	say "ERROR: expected MAX77865 ID 0x65, got $ID; refusing route write"
	exit 1
fi

say "vendor MAX77865 COM_USB_AP: CONTROL1 0x19 <- 0x89"
i2ctransfer -y "$MUIC_BUS" w2@0x66 0x19 0x89 2>&1 || true
read_muic 19

say "force gadget connect via UDC soft_connect"
for udc in /sys/class/udc/*; do
	[ -e "$udc/soft_connect" ] || continue
	say "udc=$(basename "$udc")"
	echo connect > "$udc/soft_connect" 2>&1 || true
	done
sleep 5

say "UDC state"
for udc in /sys/class/udc/*; do
	[ -e "$udc" ] || continue
	say "udc=$(basename "$udc") state=$(cat "$udc/state" 2>/dev/null || true) speed=$(cat "$udc/current_speed" 2>/dev/null || true)"
done
ip -details link show usb0 2>&1 || true
say "MAX77865 USB route experiment finished"
