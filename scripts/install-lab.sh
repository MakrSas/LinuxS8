#!/bin/bash
# Ставит/обновляет "лабораторию" в Debian на карте. Запускается на ХОСТЕ,
# телефон должен быть в TWRP.
#
# С этого момента цикл эксперимента выглядит так:
#   1. scripts/arm-experiment.sh <файл>   — положить опыт и взвести флаг
#   2. adb reboot                          — телефон уходит в Debian и сам
#                                            прогоняет опыт при загрузке
#   3. (если повис — Power+VolDown, зайти в TWRP)
#   4. scripts/collect-lab.sh              — забрать логи, пульс и ramoops
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
SD=/external_sd

"$ADB" shell "mountpoint -q $SD || mount /dev/block/mmcblk0p1 $SD" >/dev/null 2>&1 || true
"$ADB" shell "[ -d $SD/etc/systemd ]" || { echo "rootfs на карте не найден" >&2; exit 1; }

"$ADB" shell "mkdir -p $SD/root/lab"
"$ADB" push "$ROOT/scripts/lab/lab-runner.sh"          "$SD/root/lab/" >/dev/null
"$ADB" push "$ROOT/scripts/lab/dreamlte-heartbeat.sh"  "$SD/root/lab/" >/dev/null
"$ADB" push "$ROOT/scripts/lab/dreamlte-lab.service"       "$SD/etc/systemd/system/" >/dev/null
"$ADB" push "$ROOT/scripts/lab/dreamlte-heartbeat.service" "$SD/etc/systemd/system/" >/dev/null
"$ADB" push "$ROOT/scripts/lab/setup-lab-chroot.sh"    "$SD/setup-lab.sh" >/dev/null

"$ADB" shell "
mkdir -p $SD/proc $SD/sys $SD/dev
mountpoint -q $SD/proc || mount -t proc proc $SD/proc
mountpoint -q $SD/dev  || mount -o bind /dev $SD/dev
chmod 755 $SD/setup-lab.sh
chroot $SD /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM=linux /bin/bash /setup-lab.sh
rm -f $SD/setup-lab.sh
" 2>&1 | grep -E "^(===|Created symlink|.*error|.*Error)" || true

echo "лаборатория установлена"
