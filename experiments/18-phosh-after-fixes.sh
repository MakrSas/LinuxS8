#!/bin/bash
# Эксперимент 18: проверка трёх правок и разбор тачскрина.
#
# Опыт 17 показал, что phoc рисует на Mali ("GL renderer: Mali-G71 MC20
# (Panfrost)" в его собственном логе), а клиент внутри сеанса получал
# llvmpipe и 25 кадров/с. Виноват оказался /etc/environment, куда мы сами
# когда-то вписали LIBGL_ALWAYS_SOFTWARE=1 и GALLIUM_DRIVER=llvmpipe. PAM
# раздаёт этот файл всем процессам сеанса, а композитор systemd запускает
# мимо него — отсюда и расхождение.
#
# Что проверяем:
#   1. клиент в сеансе теперь на GPU?
#   2. масштаб 2 из /etc/phosh/phoc.ini применился и пережил перезагрузку?
#   3. что тачскрин на самом деле сообщает о своих координатах.
#
# Про пункт 3. Симптомы («подсветка есть, а нажатия нет», «углы это ад»)
# складываются в несовпадение масштаба: у origin всё хорошо, ошибка растёт
# к дальнему краю. Драйвер s6sy761 берёт максимумы из самого контроллера, а
# в нашем dts свойств тачскрина нет вовсе — ни размеров, ни инверсий. Если
# заявленный диапазон не совпадает с 1440x2960, лечится это парой строк
# touchscreen-size-x/y в device tree.
set -u

echo "############ ЭКСПЕРИМЕНТ 18: после правок ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"

echo ""
echo ">>> жду 60 с, пока phosh поднимется"
sleep 60

echo ""
echo "=== 1. окружение сеанса: софтверного рендера быть не должно ==="
echo "--- /etc/environment ---"
grep -vE "^#|^$" /etc/environment 2>/dev/null || echo "  (пусто, как и надо)"

echo ""
echo "=== 2. клиент внутри живого сеанса phosh ==="
RD=/run/user/1000
WD=$(ls -1 "$RD"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
if [ -z "$WD" ]; then
	echo "  сокета Wayland нет — сеанс не поднялся"
else
	su phone -c "XDG_RUNTIME_DIR=$RD WAYLAND_DISPLAY=$(basename "$WD") \
		timeout 120 glmark2-es2-wayland -b build:duration=4 -b shading:duration=4" 2>&1 \
		| grep -aE "GL_RENDERER|GL_VERSION|Surface Size|FPS|Score" | head -12
fi

echo ""
echo "=== 3. масштаб экрана (Surface Size выше скажет: 720x... значит scale=2) ==="
grep -A 2 "output:Unknown-1" /etc/phosh/phoc.ini 2>/dev/null || echo "  секции нет!"
journalctl -b --no-pager -u phosh 2>/dev/null | grep -aiE "scale|Unknown-1|mode" | tail -8

echo ""
echo "=== 4. ТАЧСКРИН: что контроллер сообщает о координатах ==="
for ev in /dev/input/event*; do
	name=$(timeout 2 evtest --info "$ev" 2>/dev/null | grep -m1 "Input device name")
	case "$name" in
	*s6sy761*)
		echo "--- $ev : $name ---"
		timeout 3 evtest "$ev" 2>&1 | sed -n '1,60p' | \
			grep -aE "Input device name|Event code .*ABS_(MT_)?POSITION|Value|Min|Max|Resolution|Properties|Testing"
		;;
	esac
done

echo ""
echo "--- для сверки: разрешение панели ---"
cat /sys/class/drm/card0-Unknown-1/modes 2>/dev/null || echo "  (нет)"

echo ""
echo "--- dmesg про тачскрин ---"
dmesg | grep -aiE "s6sy761|touch" | tail -10
echo "############ КОНЕЦ 18 ############"
