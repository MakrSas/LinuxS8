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
SD=/external_sd
OUT="$ROOT/build/lab-results/$(date +%Y%m%d-%H%M%S)"

"$ADB" shell "mountpoint -q $SD || mount /dev/block/mmcblk0p1 $SD" >/dev/null 2>&1 || true
mkdir -p "$OUT"

echo "== пульс (последние строки) =="
"$ADB" shell "tail -5 $SD/var/log/dreamlte/heartbeat 2>/dev/null" || echo "  (пульса нет)"
echo ""

echo "== эксперимент =="
LAST="$("$ADB" shell "ls -1 $SD/var/log/dreamlte/*.log 2>/dev/null | tail -1" | tr -d '\r')"
if [ -n "$LAST" ]; then
	"$ADB" shell "cat '$LAST'" | tee "$OUT/experiment.log"
else
	echo "  (логов эксперимента нет)"
fi
echo ""

echo "== ramoops с прошлой загрузки =="
"$ADB" shell "ls -1 $SD/var/lib/systemd/pstore/ 2>/dev/null" | tr -d '\r' | while read -r d; do
	[ -n "$d" ] || continue
	echo "--- $d ---"
done
"$ADB" pull "$SD/var/lib/systemd/pstore" "$OUT/pstore" >/dev/null 2>&1 && \
	echo "  сохранено в $OUT/pstore" || echo "  (пусто — прошлая загрузка не падала)"

"$ADB" pull "$SD/var/log/dreamlte/heartbeat" "$OUT/heartbeat" >/dev/null 2>&1 || true

echo ""
echo "всё сложено в $OUT"
