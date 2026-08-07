#!/bin/bash
# Эксперимент 13: Mesa на G71, на этот раз с изолированным устройством.
#
# Опыт 12 не ответил на вопрос, и виноват стенд, а не железо:
#
#  - eglinfo на платформе GBM отрапортовал llvmpipe. Это не про GPU: GBM
#    открывает первую попавшуюся карту, а первая у нас card0 = simpledrm,
#    у которой рендера нет вовсе, отсюда программный путь;
#  - es2_info оказался собран под X11 ("Error: couldn't open display"), и
#    поэтому МОЛЧА провалился даже контрольный прогон на llvmpipe. Раз не
#    прошёл контроль, ни один вывод из того опыта делать нельзя;
#  - единственное содержательное — surfaceless упал с "failed to create
#    dri2 screen". Похоже на попытку panfrost, но по этой строке нельзя
#    отличить "Mesa не умеет G71" от "выбралось не то устройство".
#
# Здесь убираем неоднозначность физически: подсовываем Mesa каталог
# /dev/dri, в котором лежит ТОЛЬКО рендер-узел panfrost. Никакого
# simpledrm, выбирать не из чего. Делается в отдельном пространстве
# монтирования, так что на саму систему это не влияет.
#
# Плюс включаем подробный лог EGL — он назовёт и устройство, и причину
# отказа, если отказ будет.
set -u

echo "############ ЭКСПЕРИМЕНТ 13: Mesa на G71, изолированно ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo ">>> modprobe panfrost"
modprobe --ignore-install panfrost 2>&1 || echo "  rc=$?"
sleep 2
ls -l /dev/dri/

# Каталог с одним только рендер-узлом. mknod, а не cp: скопировать
# устройство нельзя, его можно только создать заново по major/minor.
MAJ=226
MIN=128
rm -rf /tmp/dri-only
mkdir -p /tmp/dri-only
mknod /tmp/dri-only/renderD128 c $MAJ $MIN && chmod 666 /tmp/dri-only/renderD128
echo ""
echo "--- изолированный каталог ---"
ls -l /tmp/dri-only/

run_isolated() {
	# $1 — описание, дальше переменные окружения и команда
	local desc="$1"; shift
	echo ""
	echo "=============================================================="
	echo "$desc"
	echo "=============================================================="
	unshare -m sh -c "mount --bind /tmp/dri-only /dev/dri && $*" 2>&1 | head -40
}

run_isolated "1) panfrost в одиночестве, подробный лог EGL" \
	"env -u LIBGL_ALWAYS_SOFTWARE -u GALLIUM_DRIVER \
	 EGL_PLATFORM=surfaceless EGL_LOG_LEVEL=debug MESA_DEBUG=1 \
	 timeout 60 eglinfo -B"

run_isolated "2) то же, но драйвер назван явно" \
	"env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=panfrost \
	 MESA_LOADER_DRIVER_OVERRIDE=panfrost \
	 EGL_PLATFORM=surfaceless EGL_LOG_LEVEL=debug \
	 timeout 60 eglinfo -B"

echo ""
echo "=============================================================="
echo "3) КОНТРОЛЬ: тот же eglinfo на llvmpipe, без изоляции."
echo "   Если и он не даст GL_RENDERER — сломан стенд, а не GPU."
echo "=============================================================="
env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
	EGL_PLATFORM=surfaceless timeout 60 eglinfo -B 2>&1 | head -20

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|mali|drm" | tail -20
echo "############ КОНЕЦ 13 ############"
