#!/bin/bash
# Эксперимент 23: что дала частота 400 МГц вместо 200.
#
# Опыт 22 показал, что вялость интерфейса объясняется не поломкой, а
# частотой: при лёгком шейдере GPU давал 405 Мпикс/с, то есть один
# полноэкранный проход 1440x2960 стоил 10.5 мс. Композитору нужно
# несколько проходов на кадр — отсюда и 25 кадров в секунду.
#
# Заодно опыт 22 опроверг мой же вывод из опыта 21 про "порог по размеру":
# полный экран рисуется идеально, если шейдер лёгкий. Ломается не размер,
# а суммарная работа, не укладывающаяся в таймаут задания (500 мс).
#
# Здесь проверяем ровно две вещи:
#   1. частота действительно 400 МГц, а не осталась прежней;
#   2. пропускная способность выросла (ждём около 800 Мпикс/с).
#
# И меряем клиента внутри живого сеанса phosh — только это скажет, стало
# ли лучше на глаз, а не в синтетике.
set -u

BIN=/root/lab/gputest

echo "############ ЭКСПЕРИМЕНТ 23: GPU на 400 МГц ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 4

modprobe --ignore-install panfrost 2>/dev/null || true
sleep 2

echo ""
echo "=== 1. частота, на которой реально работаем ==="
grep -E "gout_g3d_agpu|mout_g3d_busd|dout_cmu_g3d_switch" \
	/sys/kernel/debug/clk/clk_summary 2>/dev/null \
	| awk '{printf "  %-24s %s Гц\n", $1, $5}'

MAJMIN=$(stat -c '%t %T' /dev/dri/renderD128)
MAJ=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f1))
MIN=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f2))

run() { # $1=w $2=h $3=iters
	echo ""
	echo "--- ${1}x${2}, тяжесть $3 ---"
	unshare -m sh -c "
		mount -t tmpfs -o dev,mode=0755 tmpfs /dev/dri &&
		mknod /dev/dri/renderD128 c $MAJ $MIN &&
		chmod 666 /dev/dri/renderD128 &&
		EGL_PLATFORM=surfaceless timeout 180 $BIN 20 $3 $1 $2 0
	" 2>&1 | grep -aE "рисование|кадров/с|Мпикс/с"
}

echo ""
echo "=============================================================="
echo "2. пропускная способность (на 200 МГц было 405 Мпикс/с)"
echo "=============================================================="
run 1440 2960 1
run 1440 2960 16
run 2048 2048 64

echo ""
echo "=============================================================="
echo "3. как оно в живом сеансе phosh"
echo "=============================================================="
echo ">>> жду 60 с, пока оболочка поднимется"
sleep 60
RD=/run/user/1000
WD=$(ls -1 "$RD"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
if [ -z "$WD" ]; then
	echo "  сокета Wayland нет — сеанс не поднялся"
else
	su phone -c "XDG_RUNTIME_DIR=$RD WAYLAND_DISPLAY=$(basename "$WD") \
		timeout 120 glmark2-es2-wayland -b build:duration=4 -b texture:duration=4" 2>&1 \
		| grep -aE "GL_RENDERER|Surface Size|FPS|Score" | head -10
fi

echo ""
echo "--- температура, если есть чем мерить ---"
for z in /sys/class/thermal/thermal_zone*/; do
	[ -e "$z/temp" ] || continue
	printf "  %s: %s = %s\n" "$(basename "$z")" \
		"$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"
done 2>/dev/null || echo "  (датчиков нет)"

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|sched timeout|Soft-stop|reset" | tail -12
echo "############ КОНЕЦ 23 ############"
