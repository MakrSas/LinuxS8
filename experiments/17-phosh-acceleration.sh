#!/bin/bash
# Эксперимент 17: пользуется ли phosh на самом деле GPU.
#
# cage в опыте 16 дал Mali-G71 MC20 (Panfrost) и 60 кадров/с, но
# впечатление от phosh — что ускорения нет. Проверяем, а не гадаем.
#
# Различаем три разные вещи, которые снаружи выглядят одинаково:
#   1. модуль panfrost вообще не загрузился;
#   2. загрузился, но phoc рисует на simpledrm (то есть процессором);
#   3. phoc рисует на GPU, но всё упирается в копирование кадра. У
#      simpledrm нет импорта dmabuf, поэтому каждый кадр приходится
#      перекладывать процессором: 1440*2960*4 = 17 МБ на кадр, на 60 Гц
#      это гигабайт в секунду только на memcpy.
#
# Опыт идёт из lab-runner, то есть от root и раньше phosh. Ждём, пока
# оболочка поднимется, и смотрим на живой сеанс.
set -u

echo "############ ЭКСПЕРИМЕНТ 17: пользуется ли phosh GPU ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"

echo ""
echo ">>> жду 60 с, пока phosh поднимется"
sleep 60
echo "uptime теперь: $(cut -d' ' -f1 /proc/uptime)"

echo ""
echo "=== 1. загружен ли модуль ==="
lsmod | grep -E "^panfrost|^drm" || echo "  panfrost НЕ загружен"
ls -l /dev/dri/ 2>/dev/null

echo ""
echo "=== 2. кто из процессов открыл panfrost_dri.so ==="
found=0
for p in /proc/[0-9]*; do
	if grep -qa "panfrost_dri\|libgallium" "$p/maps" 2>/dev/null; then
		if grep -qa "panfrost_dri" "$p/maps" 2>/dev/null; then
			echo "  $(basename "$p") $(tr -d '\0' < "$p/comm") -> panfrost"
			found=1
		fi
	fi
done
[ "$found" = 1 ] || echo "  НИКТО не открыл panfrost_dri.so"

echo ""
echo "=== 3. кто из процессов открыл swrast/llvmpipe ==="
for p in /proc/[0-9]*; do
	grep -qa "swrast_dri" "$p/maps" 2>/dev/null && \
		echo "  $(basename "$p") $(tr -d '\0' < "$p/comm") -> swrast"
done

echo ""
echo "=== 4. клиенты DRM по устройствам ==="
for d in /sys/kernel/debug/dri/*/; do
	[ -e "$d/clients" ] || continue
	echo "--- $d ---"
	cat "$d/clients" 2>/dev/null | head -8
done

echo ""
echo "=== 5. что сказал phoc в журнале ==="
journalctl -b --no-pager -u phosh 2>/dev/null | grep -aiE "render|drm|gpu|egl|gles|mali|llvmpipe|error|fail" | tail -25

echo ""
echo "=== 6. РЕШАЮЩЕЕ: клиент внутри живого сеанса phosh ==="
RD=/run/user/1000
WD=$(ls -1 "$RD"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
if [ -z "$WD" ]; then
	echo "  сокета Wayland нет — сеанс не поднялся?"
	ls -la "$RD" 2>/dev/null | head
else
	echo "  сокет: $WD"
	su phone -c "XDG_RUNTIME_DIR=$RD WAYLAND_DISPLAY=$(basename "$WD") \
		timeout 120 glmark2-es2-wayland -b build:duration=4 -b shading:duration=4" 2>&1 \
		| grep -aE "GL_RENDERER|GL_VERSION|Surface|FPS|Score|Error|error" | head -20
fi

echo ""
echo "=== 7. тачскрин: что видит система ==="
for d in /sys/class/input/input*/; do
	n=$(cat "$d/name" 2>/dev/null)
	case "$n" in
	*ouch*|*TSP*|*tsp*|*melfas*|*synaptics*)
		echo "  $(basename "$d"): $n"
		cat "$d/../input*/capabilities/abs" 2>/dev/null | head -1
		;;
	esac
done
echo "  --- все устройства ввода ---"
cat /proc/bus/input/devices 2>/dev/null | grep -E "^N:|^H:" | head -20

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|mali|drm|touch" | tail -20
echo "############ КОНЕЦ 17 ############"
