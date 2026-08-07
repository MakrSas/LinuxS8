#!/bin/bash
# Забирает результаты последнего эксперимента с карты. Телефон в TWRP.
#
# Три источника, по убыванию надёжности при зависании:
#   ramoops (/var/lib/systemd/pstore) — последние слова ядра, переживают
#       тёплый ребут; появляются только если прошлая загрузка умерла;
#   heartbeat — до какой секунды uptime система была жива;
#   *.log — вывод самого эксперимента, писался с fsync построчно.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
# Корень Debian теперь на внутренней памяти (sda29, бывший USERDATA).
# Карта больше не нужна: см. docs/ufs-bringup.md.
ROOT_MNT=/mnt/linuxroot
OUT="$ROOT/build/lab-results/$(date +%Y%m%d-%H%M%S)"

"$ADB" shell "mkdir -p $ROOT_MNT; mountpoint -q $ROOT_MNT || mount -t ext4 /dev/block/sda29 $ROOT_MNT" >/dev/null 2>&1 || true
mkdir -p "$OUT"

echo "== пульс (последние строки) =="
"$ADB" shell "tail -5 $ROOT_MNT/var/log/dreamlte/heartbeat 2>/dev/null" || echo "  (пульса нет)"
echo ""

echo "== эксперимент =="
# -t (по времени), а не сортировка по имени: часов с батарейкой у этого
# устройства в mainline нет, время стартует из эпохи и правится
# systemd-timesync уже на ходу, поэтому имена файлов идут не по порядку —
# свежий лог легко оказывается «раньше» старого и tail -1 берёт не тот.
LAST="$("$ADB" shell "ls -1t $ROOT_MNT/var/log/dreamlte/*.log 2>/dev/null | head -1" | tr -d '\r')"
if [ -n "$LAST" ]; then
	"$ADB" shell "cat '$LAST'" | tee "$OUT/experiment.log"
else
	echo "  (логов эксперимента нет)"
fi
echo ""

echo "== проба областей регистров =="
"$ADB" shell "cat $ROOT_MNT/var/log/dreamlte/region-probe.txt 2>/dev/null" | tee "$OUT/region-probe.txt" || echo "  (нет)"
echo ""

echo "== последние пробы стека (если сэмплер работал) =="
"$ADB" shell "tail -30 $ROOT_MNT/var/log/dreamlte/stack-samples.txt 2>/dev/null" || echo "  (проб нет)"
"$ADB" pull "$ROOT_MNT/var/log/dreamlte/stack-samples.txt" "$OUT/stack-samples.txt" >/dev/null 2>&1 || true
echo ""

echo "== ramoops с прошлой загрузки =="
"$ADB" shell "ls -1 $ROOT_MNT/var/lib/systemd/pstore/ 2>/dev/null" | tr -d '\r' | while read -r d; do
	[ -n "$d" ] || continue
	echo "--- $d ---"
done
"$ADB" pull "$ROOT_MNT/var/lib/systemd/pstore" "$OUT/pstore" >/dev/null 2>&1 && \
	echo "  сохранено в $OUT/pstore" || echo "  (пусто — прошлая загрузка не падала)"

"$ADB" pull "$ROOT_MNT/var/log/dreamlte/heartbeat" "$OUT/heartbeat" >/dev/null 2>&1 || true

echo ""
echo "всё сложено в $OUT"
