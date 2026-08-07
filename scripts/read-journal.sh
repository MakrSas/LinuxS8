#!/bin/bash
# Достаёт journal с microSD, когда телефон вернулся в TWRP.
#
# В загруженной нашим ядром системе нет ни adb, ни serial, ни сети, поэтому
# журнал на карте (journald Storage=persistent) — единственный способ узнать,
# что произошло на прошлой загрузке. journalctl берём из самого rootfs через
# chroot: он читает файлы журнала напрямую, работающий systemd ему не нужен.
#
# Использование:
#   scripts/read-journal.sh            # весь журнал последней загрузки
#   scripts/read-journal.sh -p err     # только ошибки
#   scripts/read-journal.sh -u gdm3    # конкретный юнит
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"

if ! "$ADB" get-state 2>/dev/null | grep -q .; then
	echo "Устройство не видно по adb — оно должно быть в TWRP." >&2
	exit 1
fi

# TWRP монтирует карту сам, но после ручного umount её может не быть.
"$ADB" shell 'mountpoint -q /external_sd || mount /dev/block/mmcblk0p1 /external_sd' >/dev/null 2>&1 || true

"$ADB" shell "
mkdir -p /external_sd/proc /external_sd/sys /external_sd/dev
mountpoint -q /external_sd/proc || mount -t proc proc /external_sd/proc
mountpoint -q /external_sd/dev  || mount -o bind /dev /external_sd/dev
chroot /external_sd /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM=dumb SYSTEMD_COLORS=0 \
  journalctl --no-pager --boot=-0 $* 2>&1
"
