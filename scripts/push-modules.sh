#!/bin/bash
# Раскладывает модули ядра в корневую ФС. Телефон в TWRP.
#
# Отдельным скриптом, потому что забыть этот шаг — это полдня чтения с
# экрана трассировки, которой в загруженных модулях нет (именно так и
# вышло с UFS-маркерами). Модули собираются из того же дерева, что и
# Image, но кладутся не в boot.img, а в rootfs, и синхронизировать их надо
# руками при каждой пересборке.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
LINUX="$ROOT/build/src/linux"
# Корень Debian теперь на внутренней памяти (sda29, бывший USERDATA).
# Карта больше не нужна: см. docs/ufs-bringup.md.
ROOT_MNT=/mnt/linuxroot
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# shellcheck source=/dev/null
. "$ROOT/build/toolchain/env.sh"

REL="$(cat "$LINUX/include/config/kernel.release")"
echo ">> версия ядра: $REL"

make -C "$LINUX" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install >/dev/null
# Ссылки на дерево исходников на телефоне никуда не ведут.
rm -f "$STAGE/lib/modules/$REL/build" "$STAGE/lib/modules/$REL/source"

"$ADB" shell "mkdir -p $ROOT_MNT; mountpoint -q $ROOT_MNT || mount -t ext4 /dev/block/sda29 $ROOT_MNT" >/dev/null 2>&1 || true
"$ADB" shell "rm -rf $ROOT_MNT/lib/modules/$REL; mkdir -p $ROOT_MNT/lib/modules"
"$ADB" push "$STAGE/lib/modules/$REL" "$ROOT_MNT/lib/modules/" 2>&1 | tail -1
"$ADB" shell "sync"

# UFS и PHY с 2026-08-08 собраны в ядро (=y), поэтому .ko для них больше
# нет — проверять надо не их, а что каталог модулей вообще доехал и что
# depmod построил карту зависимостей.
echo ">> проверка: разложено модулей"
"$ADB" shell "find $ROOT_MNT/lib/modules/$REL -name '*.ko*' | wc -l"
"$ADB" shell "test -s $ROOT_MNT/lib/modules/$REL/modules.dep && echo '   modules.dep на месте' || echo '   !! modules.dep пуст или отсутствует'"
