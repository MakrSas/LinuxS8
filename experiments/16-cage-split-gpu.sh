#!/bin/bash
# Эксперимент 16: рендер на GPU, вывод на simpledrm — умеет ли так cage.
#
# Mutter этого не умеет: он выбирает основным GPU card0 (simpledrm),
# panfrost отвергает как устройство без modesetting и рисует процессором,
# после чего падает. Компоузеры на wlroots такой разнос поддерживают
# штатно, и у них он настраивается прямо переменными:
#
#   WLR_DRM_DEVICES        — на чём ВЫВОДИТЬ (у нас card0, simpledrm)
#   WLR_RENDER_DRM_DEVICE  — на чём РИСОВАТЬ (у нас renderD128, panfrost)
#
# Если сработает, аппаратное ускорение приложений мы получаем уже сейчас,
# не дожидаясь настоящего драйвера дисплея. Если нет — идём писать DECON,
# зная, что дешёвого пути не было.
#
# Смотреть на строку GL_RENDERER в шапке glmark2: там должно стоять
# Mali-G71 MC20 (Panfrost), а не llvmpipe.
set -u

export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# wlroots без seatd: встроенный бэкенд libseat работает от root.
export LIBSEAT_BACKEND=builtin
export WLR_BACKENDS=drm

GLMARK="glmark2-es2-wayland -b build:duration=4 -b texture:duration=4 -b shading:duration=4"

echo "############ ЭКСПЕРИМЕНТ 16: cage, рендер и вывод врозь ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 4

echo ""
echo ">>> modprobe panfrost"
modprobe --ignore-install panfrost 2>&1 || echo "  rc=$?"
sleep 2
ls -l /dev/dri/

echo ""
echo ">>> останавливаю gdm3, чтобы освободить DRM master и консоль"
systemctl stop gdm3 2>&1 || echo "  (gdm3 не остановился, rc=$?)"
sleep 3
echo "  кто держит card0:"
fuser -v /dev/dri/card0 2>&1 | head -5 || echo "  (никто)"

echo ""
echo "=============================================================="
echo "1) Рисуем на panfrost, выводим на simpledrm"
echo "=============================================================="
# Сбросы LIBGL_ALWAYS_SOFTWARE/GALLIUM_DRIVER не нужны: их ставит только
# юнит gdm3, а опыт идёт из lab-runner со своим окружением. В прошлый раз
# я написал их после присваиваний, а env требует опции ПЕРЕД ними — и весь
# прогон свёлся к "env: '-u': No such file or directory".
WLR_DRM_DEVICES=/dev/dri/card0 \
WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 \
	timeout 240 cage -d -- $GLMARK 2>&1 | head -70
echo "  [rc=$?]"

echo ""
echo "=============================================================="
echo "2) Контроль: то же, но без указания рендер-устройства."
echo "   Покажет, что wlroots выбирает сам."
echo "=============================================================="
WLR_DRM_DEVICES=/dev/dri/card0 \
	timeout 240 cage -d -- $GLMARK 2>&1 \
	| grep -aE "GL_RENDERER|GL_VERSION|glmark2 Score|Error|error|renderer|drm|EGL" | head -25
echo "  [rc=$?]"

echo ""
echo ">>> возвращаю gdm3"
systemctl start gdm3 2>&1 || echo "  rc=$?"

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|mali|drm|gpu" | tail -25
echo "############ КОНЕЦ 16 ############"
