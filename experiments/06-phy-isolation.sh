#!/bin/bash
# Эксперимент 06: снимается ли изоляция PHY на самом деле.
#
# После правки freq-table-hz тайминги M-PHY считаются от реальной частоты
# (значения атрибутов стали настоящими: 0x28, 0x1a, 0x41, 0x9a вместо нулей),
# и жалоба на делитель PWM ушла. Но все DME-команды по-прежнему падают, а
# link startup упирается в таймаут. Значит UIC-интерфейс не оживает вообще.
#
# UniPro тактируется от M-PHY. Если PHY остаётся в изоляции, тактов нет и
# UIC молчит ровно так, как мы видим. Изоляция снимается записью в регистр
# PMU: у нас в device tree указано смещение 0x724 (то есть 0x16480724 при
# базе PMU 0x16480000), взятое из даунстрима, но НИКЕМ НЕ ПРОВЕРЕННОЕ —
# драйвер exynos7-ufs-phy по умолчанию использует 0x720, это регистр
# Exynos7420.
#
# Проверяем прямо: читаем окрестности этого регистра до загрузки модулей и
# после. Если запись прошла и подействовала, значение изменится.
set -u

cat > /tmp/rd.py <<'PYEOF'
import mmap, os, sys
page = os.sysconf('SC_PAGE_SIZE')
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
for a in sys.argv[1:]:
    addr = int(a, 16); base = addr & ~(page - 1)
    try:
        m = mmap.mmap(fd, page, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
        print('  %s = 0x%08x' % (a, int.from_bytes(m[addr-base:addr-base+4], 'little')))
        m.close()
    except Exception as e:
        print('  %s = ИСКЛЮЧЕНИЕ %s' % (a, e))
os.close(fd)
PYEOF

PMU="0x16480700 0x16480704 0x16480720 0x16480724 0x16480728 0x1648072c 0x16480730"
UFS="0x11120030 0x11120034 0x11120000"
PMA="0x11124000 0x11124004 0x1112401c 0x11124020"

echo "############ ЭКСПЕРИМЕНТ 06: изоляция PHY ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"

echo ""
echo "--- PMU ДО загрузки модулей (0x724 — наш кандидат, 0x720 — дефолт драйвера) ---"
python3 /tmp/rd.py $PMU
echo "--- контроллер ДО (HCS, HCE, CAP) ---"
python3 /tmp/rd.py $UFS
echo "--- PMA (регистры PHY) ДО ---"
python3 /tmp/rd.py $PMA
sync

MODDIR="/lib/modules/$(uname -r)/kernel"
echo ""
echo ">>> insmod phy + ufs (link startup упадёт, это ожидаемо)"
insmod "$MODDIR/drivers/phy/samsung/phy-exynos-ufs.ko" 2>&1
insmod "$MODDIR/drivers/ufs/host/ufs-exynos.ko" 2>&1
sync

echo ""
echo "--- PMU ПОСЛЕ ---"
python3 /tmp/rd.py $PMU
echo "--- контроллер ПОСЛЕ (HCS бит 3 = UCRDY, бит 0 = DP) ---"
python3 /tmp/rd.py $UFS
echo "--- PMA ПОСЛЕ (если калибровка легла, значения изменятся) ---"
python3 /tmp/rd.py $PMA

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "ufs|phy" | tail -25
echo "############ КОНЕЦ 06 ############"
