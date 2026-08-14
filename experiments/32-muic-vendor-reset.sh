#!/bin/sh
# USB bring-up, phase 2: source-backed S2MM005 reset/reprobe.
#
# The exact sequence below is s2mm005_reset() from the vendor tree:
# downstream-8895/drivers/ccic/s2mm005.c, lines 267-294.
# This is not a guessed switch write: five reads of 0x0008 wake the chip,
# then command 02 01 1c 10 01 is sent to command register 0x0010.

say() {
	echo "[muic-reset] $*"
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

say "before reset"
read_reg 0020
read_reg 0060

say "vendor s2mm005_reset: five wake reads"
i=0
while [ "$i" -lt 5 ]; do
	i2ctransfer -y "$BUS" w2@0x33 0x00 0x08 r1
	i=$((i + 1))
done

say "vendor s2mm005_reset: command 02 01 1c 10 01 at 0x0010"
i2ctransfer -y "$BUS" w7@0x33 0x00 0x10 0x02 0x01 0x1c 0x10 0x01
sleep 1

say "after reset"
read_reg 0020
read_reg 0060
say "vendor reset probe finished"
