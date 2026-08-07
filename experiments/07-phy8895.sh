#!/bin/bash
# Эксперимент 07: свой PHY-драйвер и последовательность старта линка от
# вендорского ядра universal8895.
#
# Что изменилось с прошлого прогона (там был ровно один отказ —
# "uic cmd 0x16 with arg3 0x0 completion timeout"):
#
#  - compatible PHY стал samsung,exynos8895-ufs-phy, таблица калибровки PMA
#    взята из dts даунстрима (phy-init, записи PHY_PMA_*), шаг между линиями
#    исправлен с 0xC0 на 0x140 байт;
#  - вместо четырёх тактов у PHY теперь один ref_clk;
#  - в pre_link добавлены две вендорские записи HCI, которых нет у 7420:
#    выключение HWACG (0xFC) и выбор пути опорного такта M-PHY (0x108);
#  - период такта PCS считается от pclk (12 нс), а не от mclk с округлением
#    вверх (7 нс);
#  - убран UFSHCI_QUIRK_BROKEN_HCE: даунстрим обходит HCE только у 8890;
#  - убран EXYNOS_UFS_OPT_BROKEN_RX_SEL_IDX — из-за него атрибуты PCS RX
#    уходили с селектором передатчика.
#
# Смотреть в первую очередь: пропал ли таймаут 0x16 и появились ли sd*.
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

# HCS/HCE/CAP контроллера
HCI="0x11120030 0x11120034 0x11120000"
# вендорские регистры HCI: CLKSTOP(0xB0), MISC(0xB4), ACG_DISABLE(0xFC),
# IOP_ACG(0x100), MPHY_REFCLK_SEL(0x108) — база vs_hci 0x11121100
VS="0x111211b0 0x111211b4 0x111211fc 0x11121200 0x11121208"
# PMA: COMN 0x8C и 0x74, TRSV линии 0 (0x110/0x134/0x164) и линии 1 (0x250)
PMA="0x1112408c 0x11124074 0x11124110 0x11124134 0x11124164 0x11124250"

echo "############ ЭКСПЕРИМЕНТ 07: PHY 8895 ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo "--- HCI ДО (HCS, HCE, CAP) ---"
python3 /tmp/rd.py $HCI
echo "--- vs_hci ДО (0xB0 clkstop, 0xB4 misc, 0xFC acg, 0x100 iop, 0x108 refclk_sel) ---"
python3 /tmp/rd.py $VS
echo "--- PMA ДО ---"
python3 /tmp/rd.py $PMA
sync

MODDIR="/lib/modules/$(uname -r)/kernel"

echo ""
echo ">>> insmod phy-exynos-ufs"
insmod "$MODDIR/drivers/phy/samsung/phy-exynos-ufs.ko" 2>&1 || echo "  PHY rc=$?"
sync

echo ">>> insmod ufs-exynos"
insmod "$MODDIR/drivers/ufs/host/ufs-exynos.ko" 2>&1 || echo "  UFS rc=$?"
sync
sleep 3

echo ""
echo "--- HCI ПОСЛЕ (HCS: бит0 DP, бит3 UCRDY) ---"
python3 /tmp/rd.py $HCI
echo "--- vs_hci ПОСЛЕ (ждём 0xFC бит0 = 1 и 0x108 бит0 = 1) ---"
python3 /tmp/rd.py $VS
echo "--- PMA ПОСЛЕ (калибровка должна была лечь) ---"
python3 /tmp/rd.py $PMA

echo ""
echo "--- блочные устройства ---"
grep -E "sd[a-z]" /proc/partitions || echo "  блочных устройств нет"

echo ""
echo "--- dmesg: всё про ufs/phy/uic ---"
dmesg | grep -aiE "ufs|phy|uic|unipro|scsi" | tail -60
echo "############ КОНЕЦ 07 ############"
