#!/bin/sh
# USB bring-up, phase 2: reach the separate max77854 MUIC switch.
# This is intentionally read-only.  Vendor routes AP USB through CONTROL1
# (register 0x0c), but do not write that value until the chip is identified.

say() {
	echo "[max77854-muic] $*"
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
	if echo "$target" | grep -Eq '10970000\.i2c|usi@10960000/i2c@10000|/i2c@10000$'; then
		BUS="${node##*-}"
		say "hsi2c_32 target=$target bus=$BUS"
		break
	fi
done

if [ -z "$BUS" ]; then
	say "ERROR: hsi2c_32 (10970000.i2c) adapter was not registered"
	exit 1
fi

say "read-only address scan on bus $BUS"
i2cdetect -y "$BUS" 2>&1 || true

for reg in 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 16 17 18 b5; do
	say "max77854 reg 0x$reg:"
	i2ctransfer -y "$BUS" "w1@0x66" "0x$reg" r1 2>&1 || true
done

say "read-only max77854 probe finished"
