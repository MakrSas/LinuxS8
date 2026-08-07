#!/bin/bash
# Достаёт journal с корневой ФС, когда телефон вернулся в TWRP.
#
# В загруженной нашим ядром системе нет ни adb, ни serial, ни сети, поэтому
# журнал в rootfs (journald Storage=persistent) — единственный способ узнать,
# что произошло на прошлой загрузке. journalctl берём из самого rootfs через
# chroot: он читает файлы журнала напрямую, работающий systemd ему не нужен.
#
# Корень с 2026-08-08 живёт на внутренней памяти (sda29, бывший USERDATA);
# карта больше не участвует.
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

# TWRP цепляет sda29 к /sdcard как «внутреннюю память» — монтируем отдельно,
# чтобы не зависеть от того, что он там решил.
ROOT_MNT=/mnt/linuxroot
"$ADB" shell "mkdir -p $ROOT_MNT; mountpoint -q $ROOT_MNT || mount -t ext4 /dev/block/sda29 $ROOT_MNT" >/dev/null 2>&1 || true

"$ADB" shell "
mkdir -p $ROOT_MNT/proc $ROOT_MNT/sys $ROOT_MNT/dev
mountpoint -q $ROOT_MNT/proc || mount -t proc proc $ROOT_MNT/proc
mountpoint -q $ROOT_MNT/dev  || mount -o bind /dev $ROOT_MNT/dev
chroot $ROOT_MNT /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM=dumb SYSTEMD_COLORS=0 \
  journalctl --no-pager -D /var/log/journal $* 2>&1
"
# -D, а не -b: внутри chroot нет работающего systemd, поэтому journalctl не
# знает "текущую загрузку" и на любой -b отвечает "No entries". Указываем
# каталог журналов напрямую, а нужную загрузку выбираем через
# --list-boots + --boot=<id>.
