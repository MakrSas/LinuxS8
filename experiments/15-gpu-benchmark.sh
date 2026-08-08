#!/bin/bash
# Эксперимент 15: считает ли GPU на самом деле, и насколько быстро.
#
# До сих пор про G71 у нас было только заявление драйвера — строка
# GL_RENDERER = "Mali-G71 MC20 (Panfrost)". Она собирается из таблицы
# моделей и сама по себе не доказывает, что железо что-то посчитало.
#
# gputest (patches/tools/gputest.c) закрывает этот пробел: surfaceless EGL
# прямо на рендер-узле panfrost, рисование в FBO, а потом ЧТЕНИЕ пикселей
# обратно и сверка с ожидаемым цветом. Дисплей не нужен вовсе — и это
# принципиально: любой готовый бенчмарк потребовал бы KMS, а наш KMS это
# simpledrm, через который Mesa уходит в программный растеризатор. Такой
# бенчмарк померил бы процессор, а не Mali.
#
# Прогоняем одну и ту же нагрузку дважды — на GPU и на llvmpipe. Отношение
# и будет ответом, есть ли толк от ускорения.
set -u

BIN=/root/lab/gputest
FRAMES=300
ITERS=64

echo "############ ЭКСПЕРИМЕНТ 15: считает ли GPU ############"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)"
dmesg -n 7

echo ""
echo ">>> modprobe panfrost"
modprobe --ignore-install panfrost 2>&1 || echo "  rc=$?"
sleep 2
ls -l /dev/dri/ 2>/dev/null

echo ""
echo "--- частота GPU, на которой меряем ---"
grep -E "gout_g3d_agpu|mout_g3d_busd" /sys/kernel/debug/clk/clk_summary 2>/dev/null \
	| awk '{printf "  %-22s %s Гц\n", $1, $5}' || echo "  (clk_summary недоступен)"

echo ""
echo "=============================================================="
echo "1) GPU (panfrost). Устройство изолировано, выбирать не из чего."
echo "=============================================================="
MAJMIN=$(stat -c '%t %T' /dev/dri/renderD128)
MAJ=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f1))
MIN=$(printf '%d' 0x$(echo "$MAJMIN" | cut -d' ' -f2))
unshare -m sh -c "
	mount -t tmpfs -o dev,mode=0755 tmpfs /dev/dri &&
	mknod /dev/dri/renderD128 c $MAJ $MIN &&
	chmod 666 /dev/dri/renderD128 &&
	env -u LIBGL_ALWAYS_SOFTWARE -u GALLIUM_DRIVER \
	    EGL_PLATFORM=surfaceless timeout 300 $BIN $FRAMES $ITERS
	echo \"  [rc=\$?]\"
" 2>&1

echo ""
echo "=============================================================="
echo "2) Процессор (llvmpipe), та же нагрузка — для сравнения."
echo "=============================================================="
# /dev/dri прячем целиком: без устройств Mesa уходит в swrast, и никакой
# GALLIUM_DRIVER для этого уговаривать не нужно (в Mesa 26 он всё равно
# на этом пути не работает — проверено в опыте 14).
unshare -m sh -c "
	mount -t tmpfs -o mode=0755 tmpfs /dev/dri &&
	env EGL_PLATFORM=surfaceless timeout 900 $BIN $FRAMES $ITERS
	echo \"  [rc=\$?]\"
" 2>&1

echo ""
echo "--- dmesg: не ругалось ли ядро под нагрузкой ---"
dmesg | grep -aiE "panfrost|mali|gpu fault|MMU|timeout|reset" | tail -25
echo "############ КОНЕЦ 15 ############"
