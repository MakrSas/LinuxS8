#!/bin/bash
# Эксперимент 08: смена режима питания.
#
# В опыте 07 линк UniPro наконец поднялся (link_startup_notify status=1,
# post_link отработал, устройство ответило — hba выставил dev. quirks по
# результатам чтения дескрипторов). Упёрлось на шаг дальше:
#
#   pwr ctrl cmd 0x2 with (MIBattribute 0x1571, mode 0x11) failed,
#   host upmcrs:0x0
#
# Это не таймаут: прерывание о завершении пришло, а вот статус UPMCRS
# прочитался нулём. У Exynos8895 поля UPMCRS в стандартном HCS нет, статус
# лежит в регистре UniPro 0x78EC — даунстрим включает под это отдельный
# quirk (UFSHCD_QUIRK_GET_UPMCRS_DIRECT) ровно для hw_rev 0004.
#
# Добавлен хук vops->get_upmcrs и флаг EXYNOS_UFS_OPT_UPMCRS_IN_UNIPRO.
# Заодно отключён config_sync_pattern_mask для SoC без PA_DBG_OV_TM — это
# он давал четыре ret=1 перед сменой режима.
#
# Ждём: смену режима на HS и появление /dev/sd*.
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

echo "############ ЭКСПЕРИМЕНТ 08: смена режима питания ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo "--- HCS / HCE / CAP до ---"
python3 /tmp/rd.py 0x11120030 0x11120034 0x11120000

MODDIR="/lib/modules/$(uname -r)/kernel"

echo ""
echo ">>> insmod phy-exynos-ufs"
insmod "$MODDIR/drivers/phy/samsung/phy-exynos-ufs.ko" 2>&1 || echo "  PHY rc=$?"
sync

echo ">>> insmod ufs-exynos"
insmod "$MODDIR/drivers/ufs/host/ufs-exynos.ko" 2>&1 || echo "  UFS rc=$?"
sync
sleep 5

echo ""
echo "--- блочные устройства ---"
cat /proc/partitions

echo ""
echo "--- SCSI ---"
ls -l /sys/class/scsi_device/ 2>/dev/null || echo "  нет"
for d in /sys/block/sd*; do
	[ -e "$d" ] || continue
	echo "  $d: size=$(cat "$d/size" 2>/dev/null) сект., модель=$(cat "$d/device/model" 2>/dev/null)"
done

echo ""
echo "--- проверка чтения первого сектора sda ---"
if [ -b /dev/sda ]; then
	dd if=/dev/sda of=/dev/null bs=512 count=1 2>&1
	echo "  таблица разделов:"
	grep -E "sd[a-z]" /proc/partitions
else
	echo "  /dev/sda нет"
fi

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "ufs|phy|uic|unipro|scsi|sd[a-z]" | tail -70
echo "############ КОНЕЦ 08 ############"
