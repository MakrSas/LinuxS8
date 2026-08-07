#!/bin/bash
# Эксперимент 02: поймать стек ядра ровно перед заморозкой.
#
# Что мы уже знаем после первого прогона:
#   * замирает вся система целиком, а не один поток (независимый пульс
#     оборвался на той же секунде);
#   * journal теряет последние ~5 секунд — journald буферизует;
#   * ramoops зарегистрирован ("pstore: Registered ramoops as persistent
#     store backend"), но после перезагрузки пуст — область памяти между
#     загрузками затирается, так что этот канал здесь не работает;
#   * а вот пульс уцелел. Он пишет строку и делает sync. Значит
#     запись+sync на карту — единственный канал, доживающий до заморозки.
#
# Отсюда весь замысел: грузим модуль в фоне и в максимально плотном цикле
# сбрасываем на карту /proc/PID/stack. Карта тянет порядка сотни sync'ов в
# секунду, то есть последняя уцелевшая проба будет снята за ~10 мс до
# остановки — этого хватает, чтобы назвать функцию поимённо.
#
# Экран как свидетель ненадёжен: fbcon на 1440x2960 очень медленный, и
# сообщения могут не успеть отрисоваться. Поэтому консоль здесь наоборот
# приглушаем — она бы замедлила сам сэмплер.
set -u

MODDIR="/lib/modules/$(uname -r)/kernel"
PHY="$MODDIR/drivers/phy/samsung/phy-exynos-ufs.ko"
UFS="$MODDIR/drivers/ufs/host/ufs-exynos.ko"
SAMPLES=/var/log/dreamlte/stack-samples.txt

echo "############ ЭКСПЕРИМЕНТ 02: сэмплер стека ############"
echo "ядро: $(uname -r)"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"

for f in "$PHY" "$UFS"; do
	[ -f "$f" ] || { echo "нет модуля: $f"; exit 1; }
done

echo 1 > /proc/sys/kernel/sysrq 2>/dev/null

# --- PHY -----------------------------------------------------------------
# insmod, а не modprobe: модули в blacklist, чтобы их не грузил udev сам
# (в прошлый раз он это и сделал, на 11-й секунде). insmod blacklist не
# читает. PHY в прошлый раз проходил probe целиком, грузим синхронно.
echo ">>> insmod phy-exynos-ufs"
if insmod "$PHY"; then
	echo "<<< PHY загрузился"
else
	echo "<<< PHY не загрузился (rc=$?)"
fi
sleep 1
dmesg | tail -8
sync

# --- подготовка сэмплера -------------------------------------------------
{
	echo "=== сэмплы стека, старт uptime=$(cut -d' ' -f1 /proc/uptime) ==="
} > "$SAMPLES"
sync

# Приглушаем консоль: каждая строка на fbcon это прокрутка 17 МБ
# видеопамяти, а нам нужно, чтобы цикл ниже крутился как можно чаще.
PRINTK_SAVED="$(cat /proc/sys/kernel/printk)"
dmesg -n 1

echo ">>> insmod ufs-exynos (в фоне) + плотный сэмплер стека"
echo "    пробы пишутся в $SAMPLES"
insmod "$UFS" &
PID=$!

n=0
while kill -0 "$PID" 2>/dev/null; do
	n=$((n + 1))
	# Пишем и синхронизируем на каждой итерации: всё, что не дошло до
	# карты к моменту остановки, потеряно безвозвратно.
	{
		echo "-- проба $n uptime=$(cut -d' ' -f1 /proc/uptime) state=$(cut -d' ' -f3 /proc/$PID/stat 2>/dev/null)"
		cat "/proc/$PID/stack" 2>/dev/null
	} >> "$SAMPLES"
	sync
	# Аварийный выход, чтобы опыт не крутился вечно, если модуль просто
	# долго грузится и никого не вешает.
	[ "$n" -ge 3000 ] && break
done

wait "$PID" 2>/dev/null
RC=$?

# Консоль обратно
echo "$PRINTK_SAVED" > /proc/sys/kernel/printk 2>/dev/null

echo "<<< insmod ufs-exynos завершился, rc=$RC, проб снято: $n"
echo ""
echo "--- последние пробы стека ---"
tail -40 "$SAMPLES"
echo ""
echo "--- dmesg ---"
dmesg | tail -40
echo ""
echo "--- блочные устройства ---"
grep -E "sd[a-z]" /proc/partitions || echo "  (нет)"
echo ""
echo "############ КОНЕЦ 02 ############"
