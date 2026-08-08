#!/bin/bash
# Поднимает сетевую карту по USB: телефон представляется хосту как CDC ECM.
#
# Зачем: у загруженной системы нет ни вай-фая (он висит на PCIe, а
# контроллера PCIe для 8895 в мейнлайне нет), ни adb. До сих пор любой
# обмен файлами с хостом стоил похода в TWRP и двух перезагрузок.
#
# Адреса заданы намертво, включая MAC. Это не косметика: при случайном MAC
# udev на хосте каждый раз придумывает новое имя интерфейса, и настройка
# хоста разъезжается после каждой перезагрузки телефона.
set -eu

GADGET=/sys/kernel/config/usb_gadget/dreamlte
IP_DEV=10.99.0.2
PREFIX=24

# MAC хоста и устройства. Локально администрируемые (бит 0x02), не
# конфликтуют с настоящими.
MAC_HOST=02:1d:6b:00:00:01
MAC_DEV=02:1d:6b:00:00:02

mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# Контроллер должен был появиться сам. Если его нет — PHY не поднялся, и
# дальше идти незачем: молчаливая петля тут хуже честной ошибки.
UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
if [ -z "$UDC" ]; then
	echo "нет ни одного UDC — DWC3 или PHY не завелись" >&2
	exit 1
fi
echo "контроллер: $UDC"

if [ -d "$GADGET" ]; then
	echo "" > "$GADGET/UDC" 2>/dev/null || true
else
	mkdir -p "$GADGET"
fi
cd "$GADGET"

# 1d6b:0104 — Linux Foundation, составное устройство. Свой идентификатор
# заводить незачем: хост опознаёт ECM по классу интерфейса, а не по VID.
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "dreamlte"                 > strings/0x409/serialnumber
echo "mainline"                 > strings/0x409/manufacturer
echo "Galaxy S8 USB network"    > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "CDC ECM" > configs/c.1/strings/0x409/configuration
echo 250       > configs/c.1/MaxPower

mkdir -p functions/ecm.usb0
echo "$MAC_HOST" > functions/ecm.usb0/host_addr
echo "$MAC_DEV"  > functions/ecm.usb0/dev_addr

ln -sf ../../../functions/ecm.usb0 configs/c.1/ 2>/dev/null || true

echo "$UDC" > UDC
echo "гаджет привязан к $UDC"

# Ждём появления интерфейса: он создаётся ядром асинхронно.
for _ in $(seq 1 50); do
	[ -d /sys/class/net/usb0 ] && break
	sleep 0.1
done
[ -d /sys/class/net/usb0 ] || { echo "usb0 так и не появился" >&2; exit 1; }

ip addr flush dev usb0 2>/dev/null || true
ip addr add "$IP_DEV/$PREFIX" dev usb0
ip link set usb0 up
echo "usb0 поднят: $IP_DEV/$PREFIX"
