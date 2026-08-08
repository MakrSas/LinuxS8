#!/bin/bash
# Ставит на телефон пульт лаборатории. Телефон в TWRP.
#
# Пульт нужен, чтобы перестать платить циклом перезагрузки за каждый
# вопрос вида «а как это выглядит с другим отрисовщиком». Раньше такая
# проверка стоила: взвести опыт с хоста, перезагрузиться, сходить в TWRP,
# забрать лог. Теперь — нажатие пальцем.
#
# Пульт написан на GTK3 намеренно: приложения на GTK4 с отрисовщиком ngl
# на нашем Mali-G71 рисуются сломанными, и пульт на GTK4 сам оказался бы
# нечитаемым.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
T="$ROOT/patches/tools"
R=/mnt/linuxroot

"$ADB" get-state 2>/dev/null | grep -q recovery || {
	echo "Телефон должен быть в TWRP." >&2; exit 1; }

"$ADB" shell "mkdir -p $R; mountpoint -q $R || mount -t ext4 /dev/block/sda29 $R" \
	>/dev/null 2>&1 || true

echo ">> кладу файлы"
"$ADB" push "$T/dreamlte-lab.py"      "$R/usr/local/bin/dreamlte-lab"        >/dev/null
"$ADB" push "$T/dreamlte-switch-shell" "$R/usr/local/bin/dreamlte-switch-shell" >/dev/null
"$ADB" push "$T/dreamlte-lab.desktop"  "$R/usr/share/applications/dreamlte-lab.desktop" >/dev/null
"$ADB" push "$T/dreamlte-lab-sudoers"  "$R/etc/sudoers.d/dreamlte-lab"       >/dev/null

echo ">> права"
"$ADB" shell "
chmod 755 $R/usr/local/bin/dreamlte-lab $R/usr/local/bin/dreamlte-switch-shell
chmod 644 $R/usr/share/applications/dreamlte-lab.desktop
# sudoers придирчив к правам: файл с чужими правами он молча игнорирует,
# и пульт потом просто не сможет переключить оболочку.
chmod 440 $R/etc/sudoers.d/dreamlte-lab
chown 0:0 $R/etc/sudoers.d/dreamlte-lab
sync
"

echo ">> проверка"
"$ADB" shell "
ls -l $R/usr/local/bin/dreamlte-lab $R/etc/sudoers.d/dreamlte-lab
printf 'python3-gi: '; [ -d $R/usr/lib/python3/dist-packages/gi ] && echo есть || echo НЕТ
printf 'GTK3 через gi: '; ls $R/usr/lib/aarch64-linux-gnu/girepository-1.0/Gtk-3.0.typelib >/dev/null 2>&1 && echo есть || echo НЕТ
printf 'sudo: '; ls $R/usr/bin/sudo >/dev/null 2>&1 && echo есть || echo НЕТ
"
echo ">> готово"
