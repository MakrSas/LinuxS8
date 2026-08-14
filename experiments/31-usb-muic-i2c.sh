#!/bin/sh
# USB bring-up, phase 1: prove that mainline can reach the S2MM005 MUIC.
#
# This experiment is intentionally read-only.  The switch register and the
# S2MM005 command protocol must not be guessed from the vendor tree: a wrong
# write can leave the USB-C controller in an awkward state until the next
# boot.  The bus is hsi2c_30 at MMIO 0x10950000 and the chip is 0x33.

say() {
	echo "[muic] $*"
}

say "I2C adapters"
i2cdetect -l 2>&1 || true

BUS=""
SEEN=""
for node in /sys/class/i2c-dev/i2c-* /sys/class/i2c-adapter/i2c-*; do
	[ -e "$node" ] || continue
	case " $SEEN " in
		*" $node "*) continue ;;
	esac
	SEEN="$SEEN $node"
	target="$(readlink -f "$node/device" 2>/dev/null || true)"
	name="$(cat "$node/name" 2>/dev/null || true)"
	say "${node##*/}: name=$name target=$target"
	if echo "$target" | grep -Eq '10950000\.i2c|usi@10940000/i2c@10000|/i2c@10000$'; then
		BUS="${node##*-}"
		say "hsi2c_30 target=$target bus=$BUS"
		break
	fi
done

if [ -z "$BUS" ]; then
	say "ERROR: 10950000.i2c adapter was not registered"
	exit 1
fi

say "read-only address scan on bus $BUS"
i2cdetect -y "$BUS" 2>&1 || true

for reg in 0000 0004 0008 000c 0020 0060; do
	hi="0x${reg%??}"
	lo="0x${reg#??}"
	say "S2MM005 reg 0x$reg:"
	i2ctransfer -y "$BUS" "w2@0x33" "$hi" "$lo" r4 2>&1 || true
done

say "read-only MUIC probe finished"
