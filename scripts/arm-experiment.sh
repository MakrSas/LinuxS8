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
SD=/external_sd

"$ADB" shell "mountpoint -q $SD || mount /dev/block/mmcblk0p1 $SD" >/dev/null 2>&1 || true
"$ADB" push "$EXP" "$SD/root/lab/experiment.sh" >/dev/null
"$ADB" shell "chmod 755 $SD/root/lab/experiment.sh; touch $SD/root/lab/ARMED; sync"

echo "взведено: $(basename "$EXP")"
echo "теперь:   $ADB reboot"
