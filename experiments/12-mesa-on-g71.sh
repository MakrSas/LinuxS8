#!/bin/bash
# Эксперимент 12: работает ли Mesa на Mali-G71 — без GNOME.
#
# Ядерная часть уже сделана: panfrost поднимается, опознаёт mali-g71 id
# 0x60a0 ревизии status 0x1, находит 20 ядер шейдеров и создаёт
# /dev/dri/renderD128.
#
# Открытый вопрос другой. В опыте 11 gnome-shell упал с SEGV, и по логу
# нельзя различить две причины:
#   а) конфликт настроек — в gdm3 жёстко прописаны LIBGL_ALWAYS_SOFTWARE=1
#      и GALLIUM_DRIVER=llvmpipe, поставленные когда GPU в системе не было,
#      а libEGL ругается "Not allowed to force software rendering when API
#      explicitly selects a hardware device";
#   б) Mesa на G71 действительно не работает.
#
# GNOME для такой проверки слишком крупный инструмент. Здесь мы вообще его
# не трогаем: грузим panfrost и спрашиваем Mesa напрямую, через
# surfaceless EGL на рендер-узле. Никакого дисплея, никакого композитора.
#
# Ответ читать в строках GL_RENDERER и GL_VERSION: если там появится
# "Mali-G71" — Mesa на этом чипе живая, и дело было в настройках GNOME.
set -u

echo "############ ЭКСПЕРИМЕНТ 12: Mesa на G71 без GNOME ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo ">>> modprobe panfrost"
modprobe --ignore-install panfrost 2>&1 || echo "  rc=$?"
sleep 2

echo ""
echo "--- узлы DRM ---"
ls -l /dev/dri/ 2>/dev/null
for c in /sys/class/drm/card*/device/uevent; do
	[ -e "$c" ] && echo "  $c: $(grep DRIVER "$c")"
done

echo ""
echo "--- какие DRI-драйверы есть в Mesa ---"
ls /usr/lib/aarch64-linux-gnu/dri/ | grep -iE "panfrost|swrast|kms" || true

echo ""
echo "=============================================================="
echo "1) EGL БЕЗ принуждения к софтверному рендеру (то, ради чего всё)"
echo "=============================================================="
env -u LIBGL_ALWAYS_SOFTWARE -u GALLIUM_DRIVER \
	EGL_PLATFORM=surfaceless \
	timeout 60 eglinfo -B 2>&1 | head -30
echo "  [eglinfo rc=$?]"

echo ""
echo "--- es2_info: что объявляет сам GL ---"
env -u LIBGL_ALWAYS_SOFTWARE -u GALLIUM_DRIVER \
	EGL_PLATFORM=surfaceless \
	timeout 60 es2_info 2>&1 | grep -aE "GL_RENDERER|GL_VERSION|GL_VENDOR|EGL_VENDOR|EGL_VERSION|Error|error" | head -12
echo "  [es2_info rc=$?]"

echo ""
echo "=============================================================="
echo "2) То же, но с явным указанием panfrost"
echo "=============================================================="
env -u LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER=panfrost \
	EGL_PLATFORM=surfaceless \
	timeout 60 es2_info 2>&1 | grep -aE "GL_RENDERER|GL_VERSION|GL_VENDOR|Error|error" | head -12
echo "  [rc=$?]"

echo ""
echo "=============================================================="
echo "3) Контроль: тот же тест на llvmpipe (должен пройти заведомо)"
echo "=============================================================="
env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
	EGL_PLATFORM=surfaceless \
	timeout 60 es2_info 2>&1 | grep -aE "GL_RENDERER|GL_VERSION" | head -4
echo "  [rc=$?]"

echo ""
echo "--- dmesg: что сказало ядро за время теста ---"
dmesg | grep -aiE "panfrost|mali|drm" | tail -25
echo "############ КОНЕЦ 12 ############"
