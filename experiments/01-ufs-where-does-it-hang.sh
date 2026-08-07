#!/bin/bash
# Эксперимент 01: где именно вешается UFS — и вешается ли система вообще.
#
# Прошлый заход по UFS закончился ничем ровно потому, что "зависло" было
# единственным доступным наблюдением: телефон замирал в разном месте каждую
# загрузку, а инструментом была фотография экрана. Сейчас под нами
# полноценный Debian, root-шелл и живой /proc, поэтому оба вопроса
# наконец-то измеримы:
#
#   1. Зависает СИСТЕМА или только один поток? Модуль грузим в фоне и
#      опрашиваем его раз в секунду. Если опрос продолжает печатать, а
#      modprobe не возвращается — ядро живо, застрял один процесс.
#   2. ГДЕ именно застрял? /proc/PID/stack (CONFIG_STACKTRACE=y,
#      CONFIG_KALLSYMS_ALL=y) печатает стек ядра застрявшего процесса с
#      именами функций. Это прямой ответ вместо перебора гипотез.
#
# Ничего не чинит, только измеряет.
set -u

# --- крошечный devmem на python (в Debian нет busybox) ------------------
cat > /tmp/rd.py <<'PYEOF'
import mmap, os, sys
addr = int(sys.argv[1], 16)
page = os.sysconf('SC_PAGE_SIZE')
base = addr & ~(page - 1)
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
try:
    m = mmap.mmap(fd, page, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    off = addr - base
    print('0x%08x' % int.from_bytes(m[off:off+4], 'little'))
    m.close()
except Exception as e:
    print('FAIL: %s' % e)
finally:
    os.close(fd)
PYEOF

rd() { python3 /tmp/rd.py "$1" 2>&1; }

# Полный sysrq: понадобится 'w' (список заблокированных задач) — он пишет
# в kmsg, то есть в ramoops, то есть переживёт даже жёсткое зависание.
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null

echo "############ ЭКСПЕРИМЕНТ 01: UFS ############"
echo "ядро:    $(uname -r)"
echo "cmdline: $(cat /proc/cmdline)"
echo "uptime:  $(cut -d' ' -f1 /proc/uptime)"
echo ""

echo "--- регистры FSYS0 до всякой загрузки модулей ---"
echo "  UFS CAP  0x11120000 = $(rd 0x11120000)   (ждём 0x1303FF0F)"
echo "  UFS VER  0x11120008 = $(rd 0x11120008)   (ждём 0x00000210, UFSHCI 2.1)"
echo "  sysreg   0x11020700 = $(rd 0x11020700)   (ждём 0x00000011; bus error = блок обесточен)"
echo "  PHY PMA  0x11124000 = $(rd 0x11124000)"
echo ""

echo "--- состояние узлов в device tree ---"
for n in /proc/device-tree/soc*/ufs*@*; do
	[ -d "$n" ] || continue
	echo "  $n: status=$(tr -d '\0' < "$n/status" 2>/dev/null)"
done
echo ""

# Наблюдение за фоновой загрузкой модуля: раз в секунду говорим, живы ли мы
# сами, и если модуль не вернулся — печатаем стек ядра его процесса.
watch_modprobe() {
	local mod="$1" limit="$2" pid i stuck=0

	echo ">>> modprobe $mod (в фоне, лимит ${limit}с)"
	modprobe "$mod" &
	pid=$!

	for i in $(seq 1 "$limit"); do
		if ! kill -0 "$pid" 2>/dev/null; then
			wait "$pid" 2>/dev/null
			echo "<<< $mod: modprobe вернулся за ${i}с (rc=$?)"
			return 0
		fi
		# Сам факт того, что эта строка печатается, — доказательство,
		# что система жива, что бы ни происходило с модулем.
		echo "    ...${i}s uptime=$(cut -d' ' -f1 /proc/uptime) state=$(cut -d' ' -f3 /proc/$pid/stat 2>/dev/null)"
		if [ "$i" -eq 5 ] || [ "$i" -eq 10 ] || [ "$i" -eq "$limit" ]; then
			echo "    --- стек ядра pid=$pid ---"
			cat "/proc/$pid/stack" 2>&1 | sed 's/^/    /'
			stuck=1
		fi
		sleep 1
	done

	echo "<<< $mod: НЕ ВЕРНУЛСЯ за ${limit}с — процесс застрял в ядре"
	echo "    --- финальные стеки, три подряд (движется или стоит) ---"
	for i in 1 2 3; do
		echo "    -- проба $i --"
		cat "/proc/$pid/stack" 2>&1 | sed 's/^/    /'
		sleep 1
	done
	echo "    --- sysrq w: все заблокированные задачи (уйдёт в ramoops) ---"
	echo w > /proc/sysrq-trigger 2>/dev/null
	sleep 2
	return 1
}

# PHY первым: драйвер UFS всё равно попросит его через devm_phy_get, и без
# него probe просто уйдёт в EPROBE_DEFER, смазав картину.
watch_modprobe phy-exynos-ufs 20
PHY_RC=$?
echo ""
echo "--- dmesg после PHY ---"
dmesg | tail -25
echo ""

if [ "$PHY_RC" -ne 0 ]; then
	echo "PHY сам по себе не завершился — до UFS дело не доводим,"
	echo "это уже готовый результат: вешается PHY, а не контроллер."
	exit 0
fi

echo "--- регистры после загрузки PHY ---"
echo "  PHY PMA  0x11124000 = $(rd 0x11124000)"
echo "  UFS CAP  0x11120000 = $(rd 0x11120000)"
echo ""

watch_modprobe ufs-exynos 40
UFS_RC=$?
echo ""
echo "--- dmesg после UFS ---"
dmesg | tail -40
echo ""

echo "--- появились ли блочные устройства? ---"
grep -E "sd[a-z]|ufs" /proc/partitions || echo "  (нет)"
ls /dev/sd* 2>/dev/null || echo "  /dev/sd* нет"
echo ""

echo "--- регистры в конце ---"
echo "  UFS CAP  0x11120000 = $(rd 0x11120000)"
echo "  UFS VER  0x11120008 = $(rd 0x11120008)"
echo "  HCE      0x11120034 = $(rd 0x11120034)   (бит 0 = контроллер включён)"
echo "  HCS      0x11120030 = $(rd 0x11120030)   (бит 3 UCRDY, бит 0 DP)"
echo ""
echo "############ КОНЕЦ (UFS_RC=$UFS_RC) ############"
