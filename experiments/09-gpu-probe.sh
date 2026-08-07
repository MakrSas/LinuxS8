#!/bin/bash
# Эксперимент 09: первый запуск panfrost на Mali-G71.
#
# Что появилось в ядре:
#  - блок тактов CMU_G3D (база 0x13800000): PLL_G3D, пользовательский мукс
#    от CMU_TOP, MUX_CLK_G3D_BUSD, делитель BUSP и гейты, включая
#    GATE_CLK_G3D_AGPU (0x201c) — это и есть такт самого Mali;
#  - домен питания pd_g3d на samsung,exynos5433-pd, PMU + 0x40E0;
#  - узел gpu@13900000, compatible samsung,exynos8895-mali + arm,mali-bifrost.
#
# panfrost грузим вручную, а не даём udev: если линия питания G3D не
# поднята (PMIC S2MPS17 в mainline недоступен), чтение регистров GPU
# упрётся во внешний аборт — ровно то, на чём UFS в своё время валил ядро
# в панику. Ручная загрузка оставляет рабочий стол живым.
#
# Смотреть: GPU_ID и ревизию. До сих пор мы их ни разу не видели.
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

echo "############ ЭКСПЕРИМЕНТ 09: panfrost на G71 ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo "--- домен питания: CONFIGURATION (0x164840E0) и STATUS (+4) ---"
python3 /tmp/rd.py 0x164840e0 0x164840e4

echo ""
echo "--- CMU_G3D: мукс switch_user (0x100), PLL_G3D (0x120), BUSD (0x1000), BUSP (0x1804), AGPU gate (0x201c) ---"
python3 /tmp/rd.py 0x13800100 0x13800120 0x13801000 0x13801804 0x1380201c

echo ""
echo "--- такты, которые видит ядро ---"
grep -E "g3d|agpu" /sys/kernel/debug/clk/clk_summary 2>/dev/null || echo "  (clk_summary недоступен)"

echo ""
echo "--- состояние домена питания по версии genpd ---"
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | grep -iE "^domain|G3D" || echo "  (pm_genpd недоступен)"

echo ""
echo ">>> insmod panfrost"
MODDIR="/lib/modules/$(uname -r)/kernel"
insmod "$MODDIR/drivers/gpu/drm/panfrost/panfrost.ko" 2>&1 || echo "  rc=$?"
sync
sleep 3

echo ""
echo "--- GPU-регистры после probe: GPU_ID (0x13900000), L2_FEATURES (0x004), AS_PRESENT (0x018) ---"
python3 /tmp/rd.py 0x13900000 0x13900004 0x13900018

echo ""
echo "--- узлы DRM ---"
ls -l /dev/dri/ 2>/dev/null || echo "  /dev/dri нет"
for c in /sys/class/drm/card*; do
	[ -e "$c" ] || continue
	echo "  $c -> $(cat $c/device/uevent 2>/dev/null | grep DRIVER)"
done

echo ""
echo "--- такты после probe ---"
grep -E "g3d|agpu" /sys/kernel/debug/clk/clk_summary 2>/dev/null || true

echo ""
echo "--- dmesg ---"
dmesg | grep -aiE "panfrost|mali|g3d|gpu|drm" | tail -40
echo "############ КОНЕЦ 09 ############"
