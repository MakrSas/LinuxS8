#!/bin/bash
# Эксперимент 20: где на самом деле теряются кадры.
#
# Числа, которые у меня есть, не сходятся с тем, что видно на экране:
# phoc по своему логу рисует на Mali, клиент glmark2 в сеансе даёт 34-42
# кадра, а интерфейс ощущается как программный. Значит либо я меряю не то,
# либо потери случаются после отрисовки.
#
# Проверяются две вещи, обе прямым сравнением, без догадок:
#
# 1. СКОЛЬКО СТОИТ КОПИЯ КАДРА. У simpledrm нет импорта буферов GPU, и
#    композитору приходится вычитывать готовый кадр в память процессора.
#    gputest теперь меряет это отдельно: сначала чистое рисование, потом
#    то же самое плюс glReadPixels на полный экран. Разница и есть цена
#    копии. Если она около 16 мс, то 60 кадров недостижимы в принципе.
#
# 2. ДАЁТ ЛИ GPU ЧТО-ТО КОМПОЗИТОРУ. Один и тот же клиент прогоняется в
#    cage дважды: с рендерером на Mali и с принудительным программным
#    (WLR_RENDERER=pixman). Если числа совпадут — GPU в этой цепочке не
#    помогает, и я был неправ, называя оболочку ускоренной.
set -u

BIN=/root/lab/gputest

echo "############ ЭКСПЕРИМЕНТ 20: где теряются кадры ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 4

modprobe --ignore-install panfrost 2>/dev/null || true
sleep 2

echo ""
echo "=============================================================="
echo "1) Цена копии кадра: 512x512 и полноэкранные 1440x2960"
echo "=============================================================="
MAJMIN=$(stat -c '%t %T' /dev/dri/renderD128)
MAJ=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f1))
MIN=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f2))

for size in "512 512" "1440 2960"; do
	set -- $size
	echo ""
	echo "--- ${1}x${2} ---"
	unshare -m sh -c "
		mount -t tmpfs -o dev,mode=0755 tmpfs /dev/dri &&
		mknod /dev/dri/renderD128 c $MAJ $MIN &&
		chmod 666 /dev/dri/renderD128 &&
		EGL_PLATFORM=surfaceless timeout 300 $BIN 120 64 $1 $2
	" 2>&1 | grep -aE "GL_RENDERER|рисование|кадров/с|время|на кадр|объём|Мпикс|чтением"
done

echo ""
echo ">>> останавливаю phosh, чтобы освободить экран под cage"
systemctl stop phosh 2>&1 || true
sleep 3

GLMARK="glmark2-es2-wayland -b build:duration=5 -b texture:duration=5"

echo ""
echo "=============================================================="
echo "2a) cage, композитор на Mali (как сейчас)"
echo "=============================================================="
WLR_BACKENDS=drm LIBSEAT_BACKEND=builtin XDG_RUNTIME_DIR=/run/user/0 \
WLR_DRM_DEVICES=/dev/dri/card0 \
	timeout 200 cage -- $GLMARK 2>&1 \
	| grep -aE "GL_RENDERER|Surface Size|FPS|Score" | head -10

echo ""
echo "=============================================================="
echo "2b) cage, композитор принудительно программный (pixman)"
echo "=============================================================="
WLR_BACKENDS=drm LIBSEAT_BACKEND=builtin XDG_RUNTIME_DIR=/run/user/0 \
WLR_DRM_DEVICES=/dev/dri/card0 WLR_RENDERER=pixman \
	timeout 200 cage -- $GLMARK 2>&1 \
	| grep -aE "GL_RENDERER|Surface Size|FPS|Score" | head -10

echo ""
echo ">>> возвращаю phosh"
systemctl start phosh 2>&1 || true

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|gpu|drm" | tail -12
echo "############ КОНЕЦ 20 ############"
