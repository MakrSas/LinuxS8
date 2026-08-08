#!/bin/bash
# Ставит в rootfs телефона всё для сети по USB. Телефон в TWRP.
#
# После этого обмен файлами перестаёт стоить похода в TWRP: телефон
# поднимается как сетевая карта на том же кабеле, и дальше ssh/scp.
#
# Хостовую сторону настраивает scripts/usbnet-host.sh — её надо запускать
# уже после того, как телефон загрузился.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
R=/mnt/linuxroot

"$ADB" get-state 2>/dev/null | grep -q recovery || {
	echo "Телефон должен быть в TWRP." >&2; exit 1; }

"$ADB" shell "mkdir -p $R; mountpoint -q $R || mount -t ext4 /dev/block/sda29 $R" \
	>/dev/null 2>&1 || true

echo ">> кладу файлы"
"$ADB" push "$ROOT/patches/systemd/dreamlte-usbnet.sh" \
	"$R/usr/local/sbin/dreamlte-usbnet" >/dev/null
"$ADB" push "$ROOT/patches/systemd/dreamlte-usbnet.service" \
	"$R/etc/systemd/system/dreamlte-usbnet.service" >/dev/null
"$ADB" shell "mkdir -p $R/etc/NetworkManager/conf.d"
"$ADB" push "$ROOT/patches/systemd/dreamlte-usbnet-nm.conf" \
	"$R/etc/NetworkManager/conf.d/dreamlte-usbnet.conf" >/dev/null

echo ">> права и автозапуск"
"$ADB" shell "
chmod 755 $R/usr/local/sbin/dreamlte-usbnet
chmod 644 $R/etc/systemd/system/dreamlte-usbnet.service
mkdir -p $R/etc/systemd/system/sysinit.target.wants
ln -sf ../dreamlte-usbnet.service \
       $R/etc/systemd/system/sysinit.target.wants/dreamlte-usbnet.service
sync
"

echo ">> проверка"
"$ADB" shell "
printf 'скрипт:  '; ls -l $R/usr/local/sbin/dreamlte-usbnet | awk '{print \$1}'
printf 'юнит:    '; [ -L $R/etc/systemd/system/sysinit.target.wants/dreamlte-usbnet.service ] \
	&& echo 'взведён' || echo 'НЕ ВЗВЕДЁН'
printf 'sshd:    '; [ -x $R/usr/sbin/sshd ] && echo есть || echo 'НЕТ — нужен openssh-server'
printf 'ключи:   '; ls $R/etc/ssh/ssh_host_*_key >/dev/null 2>&1 && echo есть || echo нет
"
echo ">> готово"
