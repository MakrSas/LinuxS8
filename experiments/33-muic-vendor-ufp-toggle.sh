#!/bin/sh
# USB bring-up, phase 3: source-backed UFP attach sequence.
#
# This is the exact TYPE_C_ATTACH_UFP path from the vendor driver:
# downstream-8895/drivers/ccic/s2mm005.c, s2mm005_rprd_mode_change().
# It sends 03 12 (detach), waits one second, then sends 03 14 (sink/UFP).
# The sequence is intentionally isolated from reset so the host-side probe
# can tell whether S2MM005's attach/toggle path is the missing piece.

say() {
	echo "[muic-ufp] $*"
}

BUS=""
for node in /sys/class/i2c-dev/i2c-* /sys/class/i2c-adapter/i2c-*; do
	[ -e "$node" ] || continue
	target="$(readlink -f "$node/device" 2>/dev/null || true)"
	if echo "$target" | grep -Eq '10950000\.i2c|usi@10940000/i2c@10000|/i2c@10000$'; then
		BUS="${node##*-}"
		say "hsi2c_30=$target bus=$BUS"
		break
	fi
done

if [ -z "$BUS" ]; then
	say "ERROR: hsi2c_30 adapter was not registered"
	exit 1
fi

read_reg() {
	reg="$1"
	hi="0x${reg%??}"
	lo="0x${reg#??}"
	say "reg 0x$reg:"
	i2ctransfer -y "$BUS" "w2@0x33" "$hi" "$lo" r4
}

say "before UFP toggle"
read_reg 0020
read_reg 0060

say "vendor s2mm005_rprd_mode_change(TYPE_C_ATTACH_UFP): 03 12"
i2ctransfer -y "$BUS" w4@0x33 0x00 0x10 0x03 0x12
sleep 1

say "vendor s2mm005_rprd_mode_change(TYPE_C_ATTACH_UFP): 03 14"
i2ctransfer -y "$BUS" w4@0x33 0x00 0x10 0x03 0x14
sleep 1

say "after UFP toggle"
read_reg 0020
read_reg 0060
say "vendor UFP toggle finished"
