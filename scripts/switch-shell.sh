#!/bin/bash
# Переключение оболочки: phosh <-> gnome. Телефон в TWRP.
#
#   scripts/switch-shell.sh phosh
#   scripts/switch-shell.sh gnome
#
# Обе оболочки остаются установленными, меняется только то, какой юнит
# включён в graphical.target. Это полностью обратимо и не требует
# перепрошивки.
#
# Почему вообще понадобилось: mutter (GNOME) не умеет рисовать на одном
# DRM-устройстве и выводить на другое, а у нас именно этот случай — рендер
# на panfrost, вывод на simpledrm. Компоузеры на wlroots, включая phoc под
# phosh, поддерживают такой разнос штатно. Проверено опытом 16: cage дал
# Mali-G71 MC20 (Panfrost) и 60 кадров/с в полном 1440x2960.
set -e

WHAT="${1:-}"
case "$WHAT" in
phosh|gnome) ;;
*) echo "укажите оболочку: $0 phosh|gnome" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
R=/mnt/linuxroot

"$ADB" get-state 2>/dev/null | grep -q recovery || {
	echo "Телефон должен быть в TWRP." >&2; exit 1; }

"$ADB" shell "mkdir -p $R; mountpoint -q $R || mount -t ext4 /dev/block/sda29 $R" >/dev/null 2>&1 || true

if [ "$WHAT" = phosh ]; then
	"$ADB" shell "
	rm -f $R/etc/systemd/system/graphical.target.wants/gdm3.service
	rm -f $R/etc/systemd/system/display-manager.service
	ln -sf /usr/lib/systemd/system/phosh.service \
	       $R/etc/systemd/system/graphical.target.wants/phosh.service
	# panfrost нужен: без него оболочка останется на процессоре.
	rm -f $R/etc/modprobe.d/dreamlte-gpu.conf
	sync"
else
	"$ADB" shell "
	rm -f $R/etc/systemd/system/graphical.target.wants/phosh.service
	ln -sf /usr/lib/systemd/system/gdm3.service \
	       $R/etc/systemd/system/display-manager.service
	ln -sf /usr/lib/systemd/system/gdm3.service \
	       $R/etc/systemd/system/graphical.target.wants/gdm3.service
	# GNOME с загруженным panfrost падает: mutter выбирает основным GPU
	# simpledrm и не переживает соседство рендерного устройства.
	printf '%s\n' \
	  '# GNOME не переживает появление panfrost: mutter берёт основным GPU' \
	  '# simpledrm и падает. Для phosh этот файл не нужен.' \
	  'blacklist panfrost' \
	  'install panfrost /bin/true' \
	  > $R/etc/modprobe.d/dreamlte-gpu.conf
	sync"
fi

echo ">> включена оболочка: $WHAT"
"$ADB" shell "ls -1 $R/etc/systemd/system/graphical.target.wants/"
