#!/bin/sh
# USB bring-up, phase 4: read-only MAX77865 address/register diagnosis.
#
# The vendor DT uses 0x66, while an old vendor header comment says 0x4A.
# Do not write anything here: compare both addresses and access styles.

say() {
	echo "[max77865-address] $*"
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
say "MUIC bus=$BUS"
if [ -z "$BUS" ]; then
	say "ERROR: hsi2c_32 adapter is missing"
	exit 1
fi

say "read-byte address scan"
i2cdetect -y -r "$BUS" 2>&1 || true

read_reg() {
	addr="$1"
	reg="$2"
	value="$(i2ctransfer -y "$BUS" "w1@$addr" "0x$reg" r1 2>/dev/null || true)"
	say "addr=$addr reg=0x$reg value=${value:-ERROR}"
}

for addr in 0x4a 0x66; do
	say "register reads at $addr"
	for reg in 00 01 02 03 04 07 08 09 0a 0d 0e 0f 13 14 15 19 1a 1b 1c 1d 1e; do
		read_reg "$addr" "$reg"
	done
done

say "read-only address diagnosis finished"
