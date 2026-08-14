#!/bin/sh
# USB bring-up, phase 5: read-only probe of the MAX77865 MUIC sub-address.
#
# Vendor code defines I2C_ADDR_MUIC as (0x4A >> 1), i.e. 7-bit 0x25.

say() {
	echo "[max77865-muic] $*"
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

BUS="$(find_bus '10970000.i2c' || true)"
say "MUIC bus=$BUS address=0x25"
if [ -z "$BUS" ]; then
	say "ERROR: hsi2c_32 adapter is missing"
	exit 1
fi

read_reg() {
	reg="$1"
	value="$(i2ctransfer -y "$BUS" w1@0x25 "0x$reg" r1 2>/dev/null || true)"
	say "reg=0x$reg value=${value:-ERROR}"
}

for reg in 00 01 02 03 04 07 08 09 0a 0d 0e 0f 13 14 15 19 1a 1b 1c 1d 1e; do
	read_reg "$reg"
done

say "read-only MUIC probe finished"
