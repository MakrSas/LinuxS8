#!/bin/bash
# Эксперимент 26: sway против phosh, и сбрасывается ли GPU при обычной работе.
#
# Что уже установлено замерами:
#  - GPU не узкое место: полноэкранный кадр стоит около 0.43 мс, если
#    считать по большому числу кадров, а не по двум десяткам (на малых
#    выборках всё съедал разовый расход запуска ~0.5 с — из-за него у меня
#    развалились сразу несколько прежних выводов);
#  - через cage тот же клиент даёт честные 60 кадров, то есть связка
#    Mali + panfrost + simpledrm + wlroots справляется;
#  - через phosh тот же клиент даёт 34-42, а оболочка ощущается как 25.
#
# Значит теряется всё внутри phosh. Проверяем это прямо: sway — тот же
# wlroots, но без собственной отрисовки поверх.
#
# Второй вопрос, который бьёт по любому окружению: ядро в каждом опыте
# сбрасывает GPU по таймауту заданий. Сброс посреди работы даёт рывки хоть
# в phosh, хоть в KDE. Считаем сбросы отдельно в каждой фазе.
#
# ЧТО ДЕЛАТЬ ПОЛЬЗОВАТЕЛЮ (по времени от загрузки):
#   ~0:30-2:30  оболочка phosh — просто пользуйся: листай, открывай меню
#   ~2:30-5:30  экран сменится на браузер — крути страницу пальцем
#   ~5:30       вернётся phosh
set -u

LAB=/root/lab
PHASE1=120
PHASE2=180

resets() { dmesg 2>/dev/null | grep -ac "sched timeout" || echo 0; }

echo "############ ЭКСПЕРИМЕНТ 26: sway против phosh ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 4

echo ""
echo ">>> жду 60 с, пока phosh поднимется"
sleep 60

R0=$(resets)
echo ""
echo "=============================================================="
echo "ФАЗА 1: обычная работа в phosh, $PHASE1 с"
echo "=============================================================="
echo "  сбросов GPU на старте фазы: $R0"
sleep "$PHASE1"
R1=$(resets)
echo "  сбросов GPU за фазу: $((R1 - R0))"

echo ""
echo "--- клиент в phosh для числа ---"
RD=/run/user/1000
WD=$(ls -1 "$RD"/wayland-[0-9]* 2>/dev/null | grep -v '\.lock$' | head -1)
if [ -n "$WD" ]; then
	su phone -c "XDG_RUNTIME_DIR=$RD WAYLAND_DISPLAY=$(basename "$WD") \
		timeout 90 glmark2-es2-wayland -b build:duration=4 -b texture:duration=4" 2>&1 \
		| grep -aE "GL_RENDERER|Surface Size|FPS|Score" | head -8
else
	echo "  сокета нет"
fi
R2=$(resets)
echo "  сбросов GPU за прогон glmark2: $((R2 - R1))"

echo ""
echo "=============================================================="
echo "ФАЗА 2: sway с браузером, $PHASE2 с"
echo "=============================================================="
systemctl stop phosh 2>&1 || true
sleep 3

export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export LIBSEAT_BACKEND=builtin
export WLR_BACKENDS=drm
export HOME=/root

timeout "$PHASE2" sway -c "$LAB/sway-test.conf" > /tmp/sway.log 2>&1 || true
R3=$(resets)
echo "  сбросов GPU за фазу sway: $((R3 - R2))"
echo ""
echo "--- что сказал sway ---"
grep -aiE "render|drm|gpu|mali|llvmpipe|error|fail|EGL" /tmp/sway.log | head -20

echo ""
echo ">>> возвращаю phosh"
systemctl start phosh 2>&1 || true

echo ""
echo "=============================================================="
echo "ИТОГО сбросов GPU: phosh $((R1 - R0)), glmark2 $((R2 - R1)), sway $((R3 - R2))"
echo "=============================================================="

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|sched timeout|Soft-stop|reset" | tail -12
echo "############ КОНЕЦ 26 ############"
