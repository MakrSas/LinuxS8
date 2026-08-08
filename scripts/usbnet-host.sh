#!/bin/bash
# Настраивает сторону хоста для сети по USB. Запускать, когда телефон уже
# загрузился в Debian (в TWRP этого интерфейса нет).
#
#   scripts/usbnet-host.sh          — поднять адрес
#   scripts/usbnet-host.sh --nat    — плюс раздать интернет телефону
#
# Телефон представляется как CDC ECM с фиксированным MAC (см.
# patches/systemd/dreamlte-usbnet.sh), поэтому имя интерфейса от
# перезагрузки к перезагрузке не меняется.
set -eu

IP_HOST=10.99.0.1
IP_DEV=10.99.0.2
PREFIX=24
MAC_HOST=02:1d:6b:00:00:01

NAT=""
[ "${1:-}" = "--nat" ] && NAT=1

find_iface() {
	local dev
	for dev in /sys/class/net/*; do
		[ -r "$dev/address" ] || continue
		if [ "$(cat "$dev/address")" = "$MAC_HOST" ]; then
			basename "$dev"
			return 0
		fi
	done
	return 1
}

IFACE=$(find_iface) || {
	echo "Интерфейса с MAC $MAC_HOST нет." >&2
	echo "Телефон загружен в Debian? Кабель тот же? Проверь: dmesg | tail" >&2
	exit 1
}
echo ">> интерфейс: $IFACE"

sudo ip addr flush dev "$IFACE" || true
sudo ip addr add "$IP_HOST/$PREFIX" dev "$IFACE"
sudo ip link set "$IFACE" up
echo ">> хост: $IP_HOST/$PREFIX"

if [ -n "$NAT" ]; then
	# Раздача интернета: телефон получает сеть через хост. Именно это
	# делает ненужным нынешний туннель для apt поверх adb.
	UPLINK=$(ip route show default | awk '{print $5; exit}')
	[ -n "$UPLINK" ] || { echo "нет маршрута по умолчанию, NAT пропускаю" >&2; exit 0; }
	echo ">> раздаю интернет через $UPLINK"
	sudo sysctl -q -w net.ipv4.ip_forward=1
	sudo iptables -t nat -C POSTROUTING -s "$IP_HOST/$PREFIX" -o "$UPLINK" -j MASQUERADE 2>/dev/null ||
		sudo iptables -t nat -A POSTROUTING -s "$IP_HOST/$PREFIX" -o "$UPLINK" -j MASQUERADE
	sudo iptables -C FORWARD -i "$IFACE" -o "$UPLINK" -j ACCEPT 2>/dev/null ||
		sudo iptables -A FORWARD -i "$IFACE" -o "$UPLINK" -j ACCEPT
	sudo iptables -C FORWARD -i "$UPLINK" -o "$IFACE" -m state \
		--state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
		sudo iptables -A FORWARD -i "$UPLINK" -o "$IFACE" -m state \
			--state RELATED,ESTABLISHED -j ACCEPT
fi

echo ">> проверка связи"
if ping -c 2 -W 2 "$IP_DEV" >/dev/null 2>&1; then
	echo "телефон отвечает: ssh phone@$IP_DEV"
else
	echo "телефон не отвечает на ping — посмотри журнал юнита на устройстве"
fi
