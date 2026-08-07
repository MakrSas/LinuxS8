#!/bin/bash
# Эксперимент 10: panfrost на Mali-G71, второй заход.
#
# В опыте 09 регистры GPU прочитались (GPU_ID = 0x60a00001, то есть G71
# ревизии r0p0 status 1), домен питания оказался включён, а споткнулись на
# двух вещах: такт AGPU был 0 Гц (MUX_CLK_G3D_BUSD по сбросу выбирает
# выключенный PLL_G3D) и insmod не разрешал зависимости модуля.
#
# Что появилось в ядре:
#  - блок тактов CMU_G3D (база 0x13800000): PLL_G3D, пользовательский мукс
#    от CMU_TOP, MUX_CLK_G3D_BUSD, делитель BUSP и гейты, включая
#    GATE_CLK_G3D_AGPU (0x201c) — это и есть такт самого Mali;
#  - домен питания pd_g3d на samsung,exynos5433-pd, PMU + 0x40E0;
#  - узел gpu@13900000, compatible samsung,exynos8895-mali + arm,mali-bifrost.
#
# В опыте 10 PLL_G3D не захватился ("Could not lock PLL fout_g3d_pll"), а
# PLL_CON0 остался нулём после записи — похоже, адрес регистра был взят
# неверный (0x120 из cmucal вместо 0x140 из pmucal). Адрес исправлен, но
# главное — GPU уведён с PLL на переключаемый такт из CMU_TOP, который
# заведомо жив: 200 МГц вместо 800.
#
# panfrost по-прежнему грузим вручную, а не даём udev: если он подвесит
# систему, рабочий стол останется жив.
#
# Смотреть: поднялся ли probe и появился ли рендер-узел /dev/dri/renderD128.
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

echo "############ ЭКСПЕРИМЕНТ 11: panfrost на G71 ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo "--- домен питания: CONFIGURATION (0x164840E0) и STATUS (+4) ---"
python3 /tmp/rd.py 0x164840e0 0x164840e4

echo ""
echo "--- CMU_G3D: мукс (0x100), PLL_G3D по cmucal (0x120) и по pmucal (0x140/0x148), BUSD (0x1000), BUSP (0x1804), AGPU (0x201c) ---"
python3 /tmp/rd.py 0x13800100 0x13800120 0x13800140 0x13800148 0x13801000 0x13801804 0x1380201c

echo ""
echo "--- такты, которые видит ядро ---"
grep -E "g3d|agpu" /sys/kernel/debug/clk/clk_summary 2>/dev/null || echo "  (clk_summary недоступен)"

echo ""
echo "--- состояние домена питания по версии genpd ---"
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | grep -iE "^domain|G3D" || echo "  (pm_genpd недоступен)"

echo ""
# modprobe, а не insmod: у panfrost.ko есть зависимости (drm_shmem_helper,
# gpu-sched и прочие), и голый insmod падает с "Unknown symbol in module".
# --ignore-install нужен, чтобы обойти собственный blacklist
# (install panfrost /bin/true), сохранив разрешение зависимостей.
echo ">>> modprobe panfrost"
modprobe --ignore-install panfrost 2>&1 || echo "  rc=$?"
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
echo "############ КОНЕЦ 11 ############"
