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

# The USB-C path has two external switches before DWC3:
# S2MM005 is the Type-C/CC controller on hsi2c_31 (10950000), while the
# MAX77865 MUIC parent is at 0x66 and its MUIC dummy client is at 0x25
# (vendor code: I2C_ADDR_MUIC = 0x4A >> 1).  Without these two steps the
# gadget can be configured internally but the connector remains electrically
# open.
find_i2c_bus() {
	local pattern="$1"
	local node target
	for node in /sys/class/i2c-dev/i2c-* /sys/class/i2c-adapter/i2c-*; do
		[ -e "$node" ] || continue
		target=$(readlink -f "$node/device" 2>/dev/null || true)
		case "$target" in
			*$pattern*) echo "${node##*-}"; return 0 ;;
		esac
	done
	return 1
}

route_usb_switches() {
	local ccic_bus muic_bus muic_id muic_route

	command -v i2ctransfer >/dev/null 2>&1 || {
		echo "нет i2ctransfer — не могу включить USB-C route" >&2
		return 1
	}

	ccic_bus=$(find_i2c_bus 10950000.i2c || true)
	muic_bus=$(find_i2c_bus 10970000.i2c || true)
	if [ -z "$ccic_bus" ] || [ -z "$muic_bus" ]; then
		echo "не найдены I2C-шины USB-C: ccic=$ccic_bus muic=$muic_bus" >&2
		return 1
	fi
	echo "USB-C I2C: ccic=$ccic_bus muic=$muic_bus"

	muic_id=$(i2ctransfer -y "$muic_bus" w1@0x25 0x00 r1 |
		tr -d '[:space:]\r')
	[ "$muic_id" = "0x65" ] || {
		echo "неожиданный MAX77865 MUIC ID: $muic_id" >&2
		return 1
	}

	# Vendor COM_USB_AP: D+/D- -> AP USB, no BC comparator.
	i2ctransfer -y "$muic_bus" w2@0x25 0x19 0x89
	muic_route=$(i2ctransfer -y "$muic_bus" w1@0x25 0x19 r1 |
		tr -d '[:space:]\r')
	[ "$muic_route" = "0x89" ] || {
		echo "MAX77865 MUIC route readback failed: $muic_route" >&2
		return 1
	}

	# Vendor TYPE_C_ATTACH_UFP: detach, then re-attach as sink/UFP.
	i2ctransfer -y "$ccic_bus" w4@0x33 0x00 0x10 0x03 0x12
	sleep 1
	i2ctransfer -y "$ccic_bus" w4@0x33 0x00 0x10 0x03 0x14
	sleep 1
	echo "USB-C route: MAX77865=0x89, S2MM005=UFP"
}

mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# Do this before binding the ECM gadget: the UDC may report a configured
# gadget even when the connector-side MUIC/CCIC path is still open.
route_usb_switches

# Контроллер должен был появиться сам. Если его нет — PHY не поднялся, и
# дальше идти незачем: молчаливая петля тут хуже честной ошибки.
UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
if [ -z "$UDC" ]; then
	echo "нет ни одного UDC — DWC3 или PHY не завелись" >&2
	exit 1
fi
echo "контроллер: $UDC"

if [ -d "$GADGET" ]; then
	# Отвязка: пока гаджет привязан, ядро отвергает любые изменения.
	# Ошибку не глушим — молчаливое "|| true" уже один раз спрятало
	# от нас настоящую причину.
	echo "" > "$GADGET/UDC" || echo "  (гаджет и так не был привязан)"
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

# MAC пишется только при создании функции. Как только функция подключена
# к конфигурации, ядро держит на неё ссылку и отвергает запись с EBUSY —
# на повторном запуске скрипт на этом и спотыкался.
if [ ! -d functions/ecm.usb0 ]; then
	mkdir -p functions/ecm.usb0
	echo "$MAC_HOST" > functions/ecm.usb0/host_addr
	echo "$MAC_DEV"  > functions/ecm.usb0/dev_addr
fi

# Путь ссылки configfs разбирает ОТНОСИТЕЛЬНО текущего каталога процесса,
# а не относительно места самой ссылки. Мы стоим в каталоге гаджета, значит
# писать надо ровно "functions/...". Первая версия писала сюда
# ../../../functions/... и промахивалась на уровень; ошибка при этом
# глушилась через 2>/dev/null, поэтому скрипт рапортовал успех, а гаджет
# потом не привязывался с -EINVAL: у конфигурации не было ни одной функции.
if [ ! -e configs/c.1/ecm.usb0 ]; then
	ln -s functions/ecm.usb0 configs/c.1/ecm.usb0
fi
[ -e configs/c.1/ecm.usb0 ] || { echo "функция не привязалась к конфигурации" >&2; exit 1; }

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
