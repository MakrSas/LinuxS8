#!/bin/bash
# Ставит пакеты Debian в корневую ФС телефона. Телефон в TWRP.
#
#   scripts/apt-in-chroot.sh mesa-utils mesa-utils-bin
#   scripts/apt-in-chroot.sh --suite trixie-backports libgl1-mesa-dri
#
# У загруженной системы нет ни сети, ни adb, а у TWRP нет сетевых
# драйверов. Обходим не через USB gadget networking, а проще: TCP-туннель
# поверх уже работающего adb-канала.
#
#   tinyproxy на хосте (127.0.0.1:8899)  <--  adb reverse  <--  apt в chroot
#
# Три грабли, на которые тут уже наступали (подробности — в
# docs/progress-log.md за 2026-08-07):
#
#  1. Прямого выхода в сеть у хоста нет, поэтому tinyproxy сам должен
#     ходить через прокси пользователя: "Upstream http 127.0.0.1:10809" в
#     его конфиге. Без этого он отдаёт HTTP 500.
#  2. apt роняет привилегии на пользователя _apt, которого в rootfs нет, и
#     теряет Android-группу inet (GID 3003) — без неё ядро на этом
#     устройстве запрещает открывать AF_INET сокеты. Лечится
#     APT::Sandbox::User "root".
#  3. У TWRP часы стоят на 2017 год, и проверка подписи репозитория падает
#     ("Not live until ..."). Дату выставляем с хоста перед запуском.
set -e

SUITE=""
if [ "${1:-}" = "--suite" ]; then
	SUITE="$2"; shift 2
fi

[ $# -gt 0 ] || { echo "укажите пакеты: $0 [--suite <suite>] mesa-utils ..." >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADB="$ROOT/build/tools/platform-tools/adb"
TINYPROXY="$ROOT/build/tools/tinyproxy/usr/bin/tinyproxy"
TP_CONF=/tmp/tinyproxy-run/tinyproxy.conf
ROOT_MNT=/mnt/linuxroot
PORT=8899

if ! "$ADB" get-state 2>/dev/null | grep -q recovery; then
	echo "Телефон должен быть в TWRP (adb get-state = recovery)." >&2
	exit 1
fi

if ! pgrep -f "tinyproxy -c $TP_CONF" >/dev/null 2>&1; then
	echo ">> поднимаю tinyproxy"
	"$TINYPROXY" -c "$TP_CONF"
	sleep 1
fi

echo ">> проверяю, что прокси ходит до репозитория"
code="$(curl -sS -x "http://127.0.0.1:$PORT" -o /dev/null -w '%{http_code}' \
	--max-time 30 http://deb.debian.org/debian/dists/trixie/Release || true)"
[ "$code" = "200" ] || {
	echo "   прокси не работает (HTTP $code)." >&2
	echo "   проверьте 'Upstream http 127.0.0.1:10809' в $TP_CONF" >&2
	exit 1
}

echo ">> пробрасываю порт в устройство"
"$ADB" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null

echo ">> готовлю chroot"
"$ADB" shell "
set -e
mkdir -p $ROOT_MNT
mountpoint -q $ROOT_MNT || mount -t ext4 /dev/block/sda29 $ROOT_MNT
mkdir -p $ROOT_MNT/proc $ROOT_MNT/sys $ROOT_MNT/dev
mountpoint -q $ROOT_MNT/proc || mount -t proc proc $ROOT_MNT/proc
mountpoint -q $ROOT_MNT/sys  || mount -t sysfs sysfs $ROOT_MNT/sys
mountpoint -q $ROOT_MNT/dev  || mount -o bind /dev $ROOT_MNT/dev
date -s '$(date '+%Y-%m-%d %H:%M:%S')' >/dev/null
printf '%s\n' \
  'Acquire::http::Proxy \"http://127.0.0.1:$PORT\";' \
  'APT::Sandbox::User \"root\";' \
  > $ROOT_MNT/etc/apt/apt.conf.d/99proxy
"

if [ -n "$SUITE" ]; then
	echo ">> подключаю $SUITE"
	"$ADB" shell "printf '%s\n' \
	  'deb http://deb.debian.org/debian $SUITE main' \
	  > $ROOT_MNT/etc/apt/sources.list.d/$SUITE.list"
fi

echo ">> apt-get update"
"$ADB" shell "chroot $ROOT_MNT /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM=dumb DEBIAN_FRONTEND=noninteractive \
  apt-get update" 2>&1 | tail -5

echo ">> apt-get install $*"
"$ADB" shell "chroot $ROOT_MNT /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM=dumb DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends ${SUITE:+-t $SUITE} $*" 2>&1 | tail -25

"$ADB" shell "sync"
echo ">> готово"
