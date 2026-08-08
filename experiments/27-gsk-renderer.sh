#!/bin/bash
# Эксперимент 27: дело в отрисовщике GTK4, а не в GPU.
#
# Наблюдение пользователя расставило всё по местам: сломаны настройки,
# магазин приложений, блокнот, калькулятор, часы — и все они GTK4 с
# libadwaita. А терминал GNOME, который на GTK3, рисуется нормально.
#
# GTK3 содержимое рисует процессором через cairo и GPU использует только
# для вывода готовой картинки. У GTK4 свой отрисовщик GSK, и с версии 4.14
# по умолчанию включён новый бэкенд ngl. Похоже, именно он делает на
# Bifrost v6 что-то, чего panfrost не тянет корректно.
#
# Проверяется переменной GSK_RENDERER. Запускаем один и тот же калькулятор
# три раза и снимаем скриншот каждого:
#
#   по умолчанию (ngl)  — как сейчас, для сравнения
#   gl                  — прежний бэкенд GTK4
#   cairo               — программная отрисовка содержимого, как в GTK3
#
# Если на gl или cairo картинка целая — вопрос закрыт, и это уже не
# "G71 сломан", а конкретная несовместимость с адресом.
#
# Скриншоты кладём в /root/lab/shots, оттуда заберём и посмотрим глазами.
set -u

LAB=/root/lab
SHOTS=$LAB/shots
RD=/run/user/1000

echo "############ ЭКСПЕРИМЕНТ 27: отрисовщик GTK4 ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"

echo ""
echo ">>> жду 75 с, пока phosh поднимется"
sleep 75

rm -rf "$SHOTS"; mkdir -p "$SHOTS"; chmod 777 "$SHOTS"

WD=$(ls -1 "$RD"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
if [ -z "$WD" ]; then
	echo "!! сокета Wayland нет, сеанс не поднялся"
	ls -la "$RD" 2>/dev/null | head
	exit 1
fi
WDNAME=$(basename "$WD")
echo "  сокет: $WDNAME"

echo ""
echo "--- версия GTK ---"
dpkg -l | grep -E "libgtk-4-1|libadwaita" | awk '{printf "  %s %s\n", $2, $3}'

shot() { # $1=подпись $2=значение GSK_RENDERER (пусто = по умолчанию)
	local tag="$1" rnd="${2:-}"
	echo ""
	echo "--- калькулятор, GSK_RENDERER=${rnd:-<по умолчанию>} ---"
	su phone -c "XDG_RUNTIME_DIR=$RD WAYLAND_DISPLAY=$WDNAME \
		${rnd:+GSK_RENDERER=$rnd} \
		gnome-calculator" >/tmp/app-$tag.log 2>&1 &
	local pid=$!
	sleep 18
	su phone -c "XDG_RUNTIME_DIR=$RD WAYLAND_DISPLAY=$WDNAME \
		grim $SHOTS/calc-$tag.png" 2>&1 | head -3
	ls -l "$SHOTS/calc-$tag.png" 2>/dev/null || echo "  скриншот не снялся"
	kill "$pid" 2>/dev/null
	pkill -f gnome-calculator 2>/dev/null
	sleep 3
	echo "  вывод приложения:"
	grep -aiE "error|warn|gsk|gl |egl|fail" /tmp/app-$tag.log 2>/dev/null | head -5 || true
}

shot "default" ""
shot "gl"      "gl"
shot "cairo"   "cairo"

echo ""
echo "--- что получилось ---"
ls -l "$SHOTS"
sync

echo ""
echo "--- сбросы GPU за опыт ---"
dmesg | grep -c "sched timeout" || true

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|sched timeout|Soft-stop" | tail -8
echo "############ КОНЕЦ 27 ############"
