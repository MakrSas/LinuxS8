#!/bin/bash
# Эксперимент 14: Mesa на G71 — та же изоляция, но рабочая.
#
# В опыте 13 контроль на llvmpipe прошёл, значит стенд валиден, а panfrost
# упёрся в одну строку:
#
#   libEGL warning: failed to open /dev/dri/renderD128: Permission denied
#
# И это не про Mesa. Изолированный каталог я сделал в /tmp, а /tmp у нас в
# fstab смонтирован с nodev:
#
#   tmpfs /tmp tmpfs mode=1777,nosuid,nodev
#
# С nodev ядро отказывается открывать ноду устройства на этой ФС — правами
# и root'ом это не лечится, опция запрещает саму операцию. То есть я
# подсунул Mesa заведомо мёртвую ноду и получил отказ на ровном месте.
#
# Здесь то же самое, но /dev/dri подменяется свежим tmpfs, смонтированным
# БЕЗ nodev, и нода создаётся уже внутри него. Всё по-прежнему в отдельном
# пространстве монтирования, систему не задевает.
set -u

echo "############ ЭКСПЕРИМЕНТ 14: Mesa на G71, изоляция починена ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo ">>> modprobe panfrost"
modprobe --ignore-install panfrost 2>&1 || echo "  rc=$?"
sleep 2
ls -l /dev/dri/

# Пробел между major/minor берём из настоящей ноды, а не из головы.
MAJMIN=$(stat -c '%t %T' /dev/dri/renderD128)
MAJ=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f1))
MIN=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f2))
echo ""
echo "--- renderD128 это ${MAJ}:${MIN} ---"

# tmpfs без nodev + нода внутри него. Проверка на месте: если открыть не
# удастся даже из shell, дальше идти незачем.
ISOLATE="mount -t tmpfs -o dev,mode=0755 tmpfs /dev/dri &&
	 mknod /dev/dri/renderD128 c $MAJ $MIN &&
	 chmod 666 /dev/dri/renderD128 &&
	 dd if=/dev/dri/renderD128 of=/dev/null bs=1 count=0 2>/dev/null;
	 echo \"  нода открывается: rc=\$?\";"

run_isolated() {
	local desc="$1"; shift
	echo ""
	echo "=============================================================="
	echo "$desc"
	echo "=============================================================="
	unshare -m sh -c "$ISOLATE $*" 2>&1 | head -45
}

run_isolated "1) panfrost в одиночестве" \
	"env -u LIBGL_ALWAYS_SOFTWARE -u GALLIUM_DRIVER \
	 EGL_PLATFORM=surfaceless EGL_LOG_LEVEL=debug \
	 timeout 90 eglinfo -B"

run_isolated "2) то же, но драйвер назван явно" \
	"env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=panfrost \
	 MESA_LOADER_DRIVER_OVERRIDE=panfrost \
	 EGL_PLATFORM=surfaceless EGL_LOG_LEVEL=debug \
	 timeout 90 eglinfo -B"

echo ""
echo "=============================================================="
echo "3) КОНТРОЛЬ: llvmpipe без изоляции (в опыте 13 прошёл)"
echo "=============================================================="
env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
	EGL_PLATFORM=surfaceless timeout 60 eglinfo -B 2>&1 \
	| grep -aE "renderer|version string" | head -5

echo ""
echo "--- dmesg: не ругалось ли ядро во время теста ---"
dmesg | grep -aiE "panfrost|mali|drm" | tail -20
echo "############ КОНЕЦ 14 ############"
