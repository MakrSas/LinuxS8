#!/bin/bash
# Кладёт эксперимент на карту и взводит флаг. Телефон должен быть в TWRP.
#
#   scripts/arm-experiment.sh experiments/01-alive-check.sh
#
# После этого `adb reboot` — телефон загрузится в Debian и прогонит опыт сам.
# Флаг снимается на устройстве ДО запуска опыта, так что зависание не
# превращается в петлю перезагрузок.
set -e

EXP="${1:?укажите файл эксперимента}"
[ -f "$EXP" ] || { echo "нет такого файла: $EXP" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
# Корень Debian теперь на внутренней памяти (sda29, бывший USERDATA).
# Карта больше не нужна: см. docs/ufs-bringup.md.
ROOT_MNT=/mnt/linuxroot

"$ADB" shell "mkdir -p $ROOT_MNT; mountpoint -q $ROOT_MNT || mount -t ext4 /dev/block/sda29 $ROOT_MNT" >/dev/null 2>&1 || true
"$ADB" push "$EXP" "$ROOT_MNT/root/lab/experiment.sh" >/dev/null
"$ADB" shell "chmod 755 $ROOT_MNT/root/lab/experiment.sh; touch $ROOT_MNT/root/lab/ARMED; sync"

echo "взведено: $(basename "$EXP")"
echo "теперь:   $ADB reboot"
