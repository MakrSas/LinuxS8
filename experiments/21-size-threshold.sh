#!/bin/bash
# Эксперимент 21: с какого размера GPU начинает считать неправильно.
#
# В опыте 20 один и тот же тест на 512x512 дал верные пиксели, а на
# 1440x2960 — неверные. Разница только в размере буфера. Это уже не
# производительность, а ошибка вычисления, и она хорошо объясняет
# сломанную отрисовку настроек: приложение большое и рисует в крупные
# промежуточные буферы, а оболочка и мелкие приложения — в маленькие.
#
# Здесь ищем порог и заодно проверяем главного подозреваемого — AFBC.
# Mesa при каждом запуске предупреждает:
#
#   panfrost: Tile size is smaller than AFBC superblock.
#             Rendering may not be correct
#
# Раньше я отключал AFBC в /etc/environment, но опыты идут из systemd, а
# он этот файл не читает — то есть до сих пор все замеры шли С включённым
# AFBC. Поэтому каждый размер прогоняется дважды: как есть и с noafbc.
# Если с noafbc картинка сходится, виновник назван.
#
# Проверка теперь в пяти точках, а не в одной: так видно, портится весь
# кадр или только часть.
set -u

BIN=/root/lab/gputest
FRAMES=12

echo "############ ЭКСПЕРИМЕНТ 21: порог размера ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 4

modprobe --ignore-install panfrost 2>/dev/null || true
sleep 2

MAJMIN=$(stat -c '%t %T' /dev/dri/renderD128)
MAJ=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f1))
MIN=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f2))

run() { # $1=w $2=h $3=подпись $4=доп.окружение
	echo ""
	echo "--- ${1}x${2}  [$3] ---"
	unshare -m sh -c "
		mount -t tmpfs -o dev,mode=0755 tmpfs /dev/dri &&
		mknod /dev/dri/renderD128 c $MAJ $MIN &&
		chmod 666 /dev/dri/renderD128 &&
		env $4 EGL_PLATFORM=surfaceless timeout 180 $BIN $FRAMES 64 $1 $2
	" 2>&1 | grep -aE "проверка пикселей|центр|лев\.|прав\.|рисование|Мпикс/с"
}

for wh in "256 256" "512 512" "1024 1024" "2048 2048" "1440 1440" "1440 2960"; do
	set -- $wh
	run "$1" "$2" "как есть" ""
	run "$1" "$2" "без AFBC" "PAN_MESA_DEBUG=noafbc"
done

echo ""
echo "--- dmesg: ошибки GPU под нагрузкой ---"
dmesg | grep -aiE "panfrost|gpu fault|MMU|sched|reset" | tail -15
echo "############ КОНЕЦ 21 ############"
