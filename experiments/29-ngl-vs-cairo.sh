#!/bin/bash
# Эксперимент 29: ngl против cairo, со снимками, снятыми самим опытом.
#
# Предыдущие два захода развалились из-за моих же ошибок в скрипте: сначала
# снимки писались под /root, куда пользователю phone хода нет, потом опыт
# намертво завис на запросе GSK_RENDERER=help без таймаута. Здесь каждая
# команда, которая может не вернуться, обёрнута в timeout.
#
# Список отрисовщиков GTK 4.18 получен и он короче, чем я думал:
#
#   cairo   - Cairo fallback renderer
#   opengl  \
#   ngl      >  всё это ОДИН И ТОТ ЖЕ OpenGL-отрисовщик
#   gl      /
#
# То есть выбор ровно один: ngl (сейчас) или cairo. Вариант gl, который я
# гонял в прошлый раз, молча свалился обратно на ngl.
#
# Снимки делает сам опыт, а не пользователь: в прошлый раз время снимка
# совпало с нужным прогоном, но на переднем плане оказалось другое окно.
set -u

SHOTS=/tmp/shots          # общедоступный: grim работает от пользователя phone
KEEP=/root/lab/shots      # /tmp это память, копируем на диск в конце
RD=/run/user/1000

echo "############ ЭКСПЕРИМЕНТ 29: ngl против cairo ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"

echo ">>> жду 75 с, пока phosh поднимется"
sleep 75

rm -rf "$SHOTS" "$KEEP"; mkdir -p "$SHOTS" "$KEEP"; chmod 777 "$SHOTS"

WD=$(ls -1 "$RD"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
[ -n "$WD" ] || { echo "!! сокета Wayland нет"; exit 1; }
WDNAME=$(basename "$WD")
AS="su phone -c"
ENVV="XDG_RUNTIME_DIR=$RD WAYLAND_DISPLAY=$WDNAME"

shot() { # $1=подпись $2=GSK_RENDERER (пусто = по умолчанию)
	local tag="$1" rnd="${2:-}"
	echo ""
	echo "--- калькулятор, GSK_RENDERER=${rnd:-<по умолчанию, ngl>} ---"

	pkill -f gnome-calculator 2>/dev/null; sleep 2

	$AS "$ENVV ${rnd:+GSK_RENDERER=$rnd} gnome-calculator" \
		>/tmp/app-$tag.log 2>&1 &
	sleep 20

	timeout 30 $AS "$ENVV grim $SHOTS/$tag.png" 2>&1 | head -3
	if [ -s "$SHOTS/$tag.png" ]; then
		echo "  снимок: $(stat -c%s "$SHOTS/$tag.png") байт"
	else
		echo "  !! снимок не получился"
	fi

	pkill -f gnome-calculator 2>/dev/null; sleep 3
	grep -aiE "gsk|error|fail" /tmp/app-$tag.log 2>/dev/null | head -3 || true
}

shot "1-ngl"   ""
shot "2-cairo" "cairo"

# Контрольный снимок без единого приложения: видно, цела ли сама оболочка.
pkill -f gnome-calculator 2>/dev/null; sleep 3
timeout 30 $AS "$ENVV grim $SHOTS/3-shell.png" 2>&1 | head -2

echo ""
echo "--- итог ---"
cp -f "$SHOTS"/*.png "$KEEP"/ 2>/dev/null
ls -l "$KEEP"
sync
echo "############ КОНЕЦ 29 ############"
