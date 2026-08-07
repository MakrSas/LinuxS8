#!/bin/bash
# Раскладывает модули ядра на карту. Телефон в TWRP.
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
SD=/external_sd
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# shellcheck source=/dev/null
. "$ROOT/build/toolchain/env.sh"

REL="$(cat "$LINUX/include/config/kernel.release")"
echo ">> версия ядра: $REL"

make -C "$LINUX" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install >/dev/null
# Ссылки на дерево исходников на телефоне никуда не ведут.
rm -f "$STAGE/lib/modules/$REL/build" "$STAGE/lib/modules/$REL/source"

"$ADB" shell "mountpoint -q $SD || mount /dev/block/mmcblk0p1 $SD" >/dev/null 2>&1 || true
"$ADB" shell "rm -rf $SD/lib/modules/$REL; mkdir -p $SD/lib/modules"
"$ADB" push "$STAGE/lib/modules/$REL" "$SD/lib/modules/" 2>&1 | tail -1
"$ADB" shell "sync"

echo ">> проверка: маркеры трассировки в разложенном ufs-exynos.ko"
"$ADB" shell "strings $SD/lib/modules/$REL/kernel/drivers/ufs/host/ufs-exynos.ko 2>/dev/null | grep -c UFSTRACE" || true
