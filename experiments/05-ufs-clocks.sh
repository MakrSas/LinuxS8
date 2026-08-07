#!/bin/bash
# Эксперимент 05: какие частоты реально получают клоки UFS.
#
# Зацепка из прошлого прогона — строчка
#   "failed to decide pwm clock divider, will not change"
# Её печатает exynos_ufs_calc_pwm_clk_div(), когда ни один делитель из
# {32,16,8,4} не даёт PWM-клок в диапазоне 3..9 МГц. Формула:
#
#   _clk = 1e9 * 20 / (period_ns * div * 30),   period_ns = 1e9 / mclk_rate
#
# Отсюда допустимый mclk_rate — примерно от 18 МГц до 434 МГц. Ни один
# делитель не подходит, только если частота вне этого окна. Ноль отпадает
# (было бы деление на ноль в period), значит она СЛИШКОМ ВЫСОКАЯ.
#
# А mclk_rate — это буквально clk_get_rate(sclk_unipro_main). Причём в узле
# ufs у нас, как когда-то у microSD, не задан assigned-clock-rates: там это
# ровно и оказалось причиной (контроллер сидел на 41.64 МГц вместо 50,
# потому что бутлоадер оставил PLL на 666.25 МГц и делитель был случайный).
#
# Ничего не грузим и не пишем — только читаем.
set -u

echo "############ ЭКСПЕРИМЕНТ 05: клоки UFS ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"

mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

echo ""
echo "--- клоки UFS и всё вокруг FSYS0 ---"
# clk_summary: имя, включений, готовностей, частота, ...
grep -iE "ufs|fsys0|unipro" /sys/kernel/debug/clk/clk_summary 2>&1 | head -40

echo ""
echo "--- опорные генераторы и PLL, от которых это считается ---"
grep -iE "oscclk|shared[0-9]*_pll|fout_" /sys/kernel/debug/clk/clk_summary 2>&1 | head -20

echo ""
echo "--- что видит драйвер (clk_get_rate этих двух и решает всё) ---"
echo "    core_clk        = CLK_GOUT_FSYS0_UFS_EMBD_I_ACLK"
echo "    sclk_unipro_main = CLK_GOUT_FSYS0_UFS_EMBD_I_CLK_UNIPRO"
echo "    допустимый pclk (core_clk): 70..267 МГц"
echo "    допустимый mclk (unipro):   ~18..434 МГц, иначе делитель не найдётся"

echo ""
echo "--- регистры контроллера сейчас (драйвер НЕ загружен) ---"
cat > /tmp/rd.py <<'PYEOF'
import mmap, os, sys
addr = int(sys.argv[1], 16)
page = os.sysconf('SC_PAGE_SIZE')
base = addr & ~(page - 1)
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
try:
    m = mmap.mmap(fd, page, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    print('0x%08x' % int.from_bytes(m[addr - base:addr - base + 4], 'little'))
    m.close()
except Exception as e:
    print('ИСКЛЮЧЕНИЕ: %s' % e)
finally:
    os.close(fd)
PYEOF
echo "  CAP 0x11120000 = $(python3 /tmp/rd.py 0x11120000)"
echo "  VER 0x11120008 = $(python3 /tmp/rd.py 0x11120008)"
echo "  HCS 0x11120030 = $(python3 /tmp/rd.py 0x11120030)   (бит 3 UCRDY = UIC готов, бит 0 DP)"
echo "  HCE 0x11120034 = $(python3 /tmp/rd.py 0x11120034)   (бит 0 = контроллер включён)"

echo ""
echo "--- дерево клоков целиком (на случай если имена другие) ---"
head -3 /sys/kernel/debug/clk/clk_summary 2>&1
wc -l /sys/kernel/debug/clk/clk_summary 2>&1
cp /sys/kernel/debug/clk/clk_summary /var/log/dreamlte/clk_summary.txt 2>/dev/null && \
	echo "полное дерево сохранено в /var/log/dreamlte/clk_summary.txt"
sync

echo "############ КОНЕЦ 05 ############"
