#!/bin/bash
# Собирает загрузочный образ для dreamlte из того, что уже лежит в build/.
#
# Цепочка: ядро (Image) + dtb + initramfs упаковываются внутрь uniLoader,
# а uniLoader кладётся на место ядра в стоковый boot.img (заголовок
# оригинала не трогаем — S-Boot проверяет именно его, см. repack-bootimg.py).
#
# Использование:
#   scripts/build-boot.sh <имя-образа> [--kernel]
#
# Без --kernel ядро не пересобирается — берётся уже готовый
# build/src/uniLoader/blob/Image. Пересборка ядра нужна только когда меняли
# исходники ядра или dts; изменения в initramfs её не требуют, а занимает
# она несколько минут.
set -e

NAME="${1:?укажите имя образа, например: scripts/build-boot.sh sdworks}"
REBUILD_KERNEL="${2:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
LINUX="$BUILD/src/linux"
UNILOADER="$BUILD/src/uniLoader"
OUT="$BUILD/device-backups/boot_${NAME}.img"

# shellcheck source=/dev/null
. "$BUILD/toolchain/env.sh"

if [ "$REBUILD_KERNEL" = "--kernel" ]; then
	echo ">> ядро"
	# modules обязательно вместе с Image: UFS и PHY собраны модулями, и
	# "make Image dtbs" их не трогает. На этом уже обожглись — разложили
	# на телефон .ko четырёхчасовой давности и полдня читали с экрана
	# трассировку, которой в них не было.
	make -C "$LINUX" -j"$(nproc)" Image dtbs modules
	cp "$LINUX/arch/arm64/boot/Image" "$UNILOADER/blob/Image"
	cp "$LINUX/arch/arm64/boot/dts/exynos/exynos8895-dreamlte.dtb" "$UNILOADER/blob/dtb"
fi

echo ">> initramfs"
cp "$ROOT/patches/initramfs/init" "$BUILD/initramfs/init"
chmod 755 "$BUILD/initramfs/init"
# gen_init_cpio, а не find|cpio: на хосте нет root, а device-ноды
# (/dev/console, /dev/null) в архиве нужны — их можно только описать
# манифестом, создать в ФС нечем.
"$BUILD/gen-manifest.sh" > "$BUILD/initramfs.manifest"
"$LINUX/usr/gen_init_cpio" "$BUILD/initramfs.manifest" > "$BUILD/initramfs.cpio"
gzip -9 -c "$BUILD/initramfs.cpio" > "$BUILD/initramfs.cpio.gz"
cp "$BUILD/initramfs.cpio.gz" "$UNILOADER/blob/ramdisk"

echo ">> uniLoader"
# ARCH=aarch64, а не arm64: у uniLoader каталог называется arch/aarch64, и
# ARCH=arm64 из toolchain/env.sh (он для ядра) уводит сборку в несуществующий
# arch/arm64 с ошибкой про linker.lds.S.
make -C "$UNILOADER" ARCH=aarch64 -j"$(nproc)" >/dev/null

echo ">> boot.img"
python3 "$ROOT/scripts/repack-bootimg.py" \
	"$BUILD/device-backups/boot_orig.img" \
	"$UNILOADER/uniLoader" \
	"$OUT"

echo ""
ls -l "$OUT"
md5sum "$OUT"
