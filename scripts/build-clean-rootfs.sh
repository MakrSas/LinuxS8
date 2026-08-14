#!/usr/bin/env bash
# Собирает чистый Debian arm64 rootfs из официального зеркала Debian.
#
# Этот скрипт только создаёт локальный rootfs и архив. Он не форматирует
# разделы и не обращается к телефону — записью на устройство занимается
# scripts/installer.py после отдельных подтверждений пользователя.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="trixie"
MIRROR="https://deb.debian.org/debian"
DESKTOP="phosh"
LINUX_USER="phone"
LINUX_HOSTNAME="dreamlte"
ROOT_LABEL="linuxroot"
SCALE="3"
OUT=""
KERNEL_TREE=""
PASSWORD_FILE=""
CLEAN_OUTPUT=0

usage() {
	cat <<'EOF'
Использование:
  scripts/build-clean-rootfs.sh [параметры]

Параметры:
  --suite SUITE          trixie (по умолчанию), bookworm или stable
  --mirror URL           официальное зеркало Debian
  --desktop NAME         phosh (по умолчанию) или gnome
  --user NAME            имя обычного пользователя (по умолчанию phone)
  --hostname NAME        имя телефона (по умолчанию dreamlte)
  --root-label LABEL     метка ext4 (по умолчанию linuxroot)
  --scale N              целый масштаб UI, по умолчанию 3 (300%%)
  --output DIR           каталог временного rootfs
  --kernel-tree DIR      установить модули из дерева собранного ядра
  --password-file FILE   временный файл с паролем пользователя
  --clean-output         удалить незавершённый rootfs этого установщика
  --help

Пароль пользователя запрашивается без отображения символов после сборки.
Архив создаётся рядом с каталогом rootfs как <output>.tar.gz.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--suite)       SUITE="${2:?--suite требует значения}"; shift 2 ;;
	--mirror)      MIRROR="${2:?--mirror требует значения}"; shift 2 ;;
	--desktop)     DESKTOP="${2:?--desktop требует значения}"; shift 2 ;;
	--user)        LINUX_USER="${2:?--user требует значения}"; shift 2 ;;
	--hostname)    LINUX_HOSTNAME="${2:?--hostname требует значения}"; shift 2 ;;
	--root-label)  ROOT_LABEL="${2:?--root-label требует значения}"; shift 2 ;;
	--scale)       SCALE="${2:?--scale требует значения}"; shift 2 ;;
	--output)      OUT="${2:?--output требует значения}"; shift 2 ;;
	--kernel-tree) KERNEL_TREE="${2:?--kernel-tree требует значения}"; shift 2 ;;
	--password-file) PASSWORD_FILE="${2:?--password-file требует значения}"; shift 2 ;;
	--clean-output) CLEAN_OUTPUT=1; shift ;;
	--help|-h)     usage; exit 0 ;;
	*)             echo "неизвестный параметр: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$SUITE" in
	trixie|bookworm|stable) ;;
	*) echo "поддерживаются suite: trixie, bookworm, stable" >&2; exit 2 ;;
esac
case "$DESKTOP" in
	phosh|gnome) ;;
	*) echo "поддерживаются desktop: phosh, gnome" >&2; exit 2 ;;
esac
case "$SCALE" in
	1|2|3|4) ;;
	*) echo "--scale должен быть целым числом 1..4; 3 = 300%%" >&2; exit 2 ;;
esac
LINUX_USER="${LINUX_USER,,}"
[[ "$LINUX_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
	echo "недопустимое имя пользователя: $LINUX_USER" >&2; exit 2; }
[[ "$LINUX_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
	echo "недопустимое имя hostname: $LINUX_HOSTNAME" >&2; exit 2; }
[[ "$ROOT_LABEL" =~ ^[a-zA-Z0-9._-]{1,16}$ ]] || {
	echo "недопустимая метка ext4: $ROOT_LABEL" >&2; exit 2; }
if [ -n "$PASSWORD_FILE" ]; then
	[ -r "$PASSWORD_FILE" ] || { echo "не читается password file: $PASSWORD_FILE" >&2; exit 1; }
	LINUX_USER_PASSWORD="$(head -n 1 "$PASSWORD_FILE")"
fi

[ "$(id -u)" -eq 0 ] || {
	echo "сборщик должен запускаться от root; Linux: sudo $0 ..." >&2; exit 1; }
command -v debootstrap >/dev/null 2>&1 || {
	echo "не найден debootstrap. Установите: sudo apt-get update && sudo apt-get install -y debootstrap" >&2
	exit 1; }
command -v chroot >/dev/null 2>&1 || {
	echo "не найден chroot." >&2; exit 1; }
command -v mount >/dev/null 2>&1 || {
	echo "не найден mount." >&2; exit 1; }

if [ -z "$OUT" ]; then
	OUT="$ROOT/build/installer/rootfs-${SUITE}-${DESKTOP}"
fi
OUT="$(readlink -f "$OUT")"
ARCHIVE="${OUT}.tar.gz"

# Не разрешаем случайно выбрать корень проекта или системную папку.
case "$OUT" in
	/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/mnt|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/var|"$ROOT"|"$ROOT/build")
		echo "опасный каталог вывода: $OUT" >&2; exit 2 ;;
esac
if [ -e "$OUT" ]; then
	[ -d "$OUT" ] || { echo "output существует и не является каталогом: $OUT" >&2; exit 1; }
	if [ -n "$(find "$OUT" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
		if [ "$CLEAN_OUTPUT" -ne 1 ]; then
			echo "output должен быть новым или пустым: $OUT" >&2
			echo "Для очистки незавершённой сборки добавьте --clean-output." >&2
			exit 1
		fi
		case "$OUT" in
			"$ROOT/build/installer"/rootfs-*) ;;
			*) echo "отказ: --clean-output разрешён только для build/installer/rootfs-*" >&2; exit 2 ;;
		esac
		for mount_dir in "$OUT/dev" "$OUT/sys" "$OUT/proc"; do
			if mountpoint -q "$mount_dir" 2>/dev/null; then
				umount -R "$mount_dir" 2>/dev/null || true
			fi
		done
		rm -rf -- "$OUT"
		rm -f -- "$ARCHIVE"
		mkdir -p "$OUT"
	fi
else
	mkdir -p "$OUT"
fi

LOG_FILE="${OUT}.log"
: > "$LOG_FILE"
on_error() {
	status=$?
	set +e
	echo "!! сборка остановлена с кодом $status" >&2
	echo "   полный журнал: $LOG_FILE" >&2
	if [ -s "$LOG_FILE" ]; then
		echo "   последние строки:" >&2
		tail -n 30 "$LOG_FILE" >&2
	fi
	exit "$status"
}
trap on_error ERR

cleanup_mounts() {
	set +e
	if mountpoint -q "$OUT/dev" 2>/dev/null; then umount -R "$OUT/dev"; fi
	if mountpoint -q "$OUT/sys" 2>/dev/null; then umount -R "$OUT/sys"; fi
	if mountpoint -q "$OUT/proc" 2>/dev/null; then umount -R "$OUT/proc"; fi
	if [ -e "$OUT/usr/bin/qemu-aarch64-static" ]; then
		rm -f "$OUT/usr/bin/qemu-aarch64-static"
	fi
}
trap cleanup_mounts EXIT

host_arch="$(uname -m)"
BOOTSTRAP_MODE="native"
if [ "$host_arch" != arm64 ] && [ "$host_arch" != aarch64 ]; then
	if command -v qemu-debootstrap >/dev/null 2>&1; then
		BOOTSTRAP_MODE="qemu-debootstrap"
	elif [ -x /usr/bin/qemu-aarch64-static ]; then
		BOOTSTRAP_MODE="foreign"
		if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
			echo "qemu-aarch64-static найден, но binfmt_misc не зарегистрирован." >&2
			echo "Установите qemu-user-static и binfmt-support, затем повторите." >&2
			exit 1
		fi
	else
		echo "Для сборки arm64 на $host_arch нужен qemu-debootstrap или qemu-aarch64-static." >&2
		exit 1
	fi
fi

echo ">> Debian $SUITE arm64, desktop=$DESKTOP, scale=${SCALE}00%%"
echo ">> output: $OUT"
echo ">> bootstrap: $BOOTSTRAP_MODE"

echo ">> скачиваю и распаковываю базовую систему Debian"
if [ "$BOOTSTRAP_MODE" = qemu-debootstrap ]; then
	qemu-debootstrap --arch=arm64 --variant=minbase "$SUITE" "$OUT" "$MIRROR" \
		>>"$LOG_FILE" 2>&1
else
	if [ "$BOOTSTRAP_MODE" = native ]; then
		debootstrap --arch=arm64 --variant=minbase "$SUITE" "$OUT" "$MIRROR" \
			>>"$LOG_FILE" 2>&1
	else
		debootstrap --foreign --arch=arm64 --variant=minbase "$SUITE" "$OUT" "$MIRROR" \
			>>"$LOG_FILE" 2>&1
		install -m 0755 /usr/bin/qemu-aarch64-static "$OUT/usr/bin/qemu-aarch64-static"
	fi
fi

mkdir -p "$OUT/proc" "$OUT/sys" "$OUT/dev"
mount -t proc proc "$OUT/proc"
mount --rbind /sys "$OUT/sys"
mount --make-rslave "$OUT/sys"
mount --rbind /dev "$OUT/dev"
mount --make-rslave "$OUT/dev"

if [ "$BOOTSTRAP_MODE" = foreign ]; then
	echo ">> завершаю второй этап Debian bootstrap"
	chroot "$OUT" /debootstrap/debootstrap --second-stage \
		>>"$LOG_FILE" 2>&1
fi

cat > "$OUT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free-firmware
EOF
cat > "$OUT/etc/apt/apt.conf.d/99installer" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
DPkg::Options {
  "--force-confdef";
  "--force-confold";
};
EOF
cat > "$OUT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$OUT/usr/sbin/policy-rc.d"

if [ -r /etc/resolv.conf ]; then
	rm -f "$OUT/etc/resolv.conf"
	cp -L /etc/resolv.conf "$OUT/etc/resolv.conf"
else
	rm -f "$OUT/etc/resolv.conf"
	printf 'nameserver 1.1.1.1\n' > "$OUT/etc/resolv.conf"
fi

chroot_env() {
	chroot "$OUT" /usr/bin/env -i \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		HOME=/root DEBIAN_FRONTEND=noninteractive \
		HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}" \
		HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}" \
		NO_PROXY="${NO_PROXY:-${no_proxy:-}}" \
		"$@"
}

echo ">> устанавливаю системные пакеты и графическую оболочку"
chroot_env apt-get update >>"$LOG_FILE" 2>&1

COMMON_PACKAGES=(
	systemd systemd-sysv dbus sudo openssh-server network-manager
	ca-certificates locales tzdata kmod udev e2fsprogs mount procps
	iproute2 i2c-tools less nano
)
DESKTOP_PACKAGES=()
if [ "$DESKTOP" = phosh ]; then
	DESKTOP_PACKAGES=(phosh phoc squeekboard)
else
	DESKTOP_PACKAGES=(gdm3 gnome-core)
fi

chroot_env apt-get install -y "${COMMON_PACKAGES[@]}" "${DESKTOP_PACKAGES[@]}" \
	>>"$LOG_FILE" 2>&1

printf 'en_US.UTF-8 UTF-8\n' > "$OUT/etc/locale.gen"
echo ">> генерирую локаль и настраиваю систему"
chroot_env locale-gen en_US.UTF-8 >>"$LOG_FILE" 2>&1
ln -sf /usr/share/zoneinfo/UTC "$OUT/etc/localtime"
printf 'UTC\n' > "$OUT/etc/timezone"

install -m 0755 "$ROOT/scripts/setup-rootfs-session.sh" \
	"$OUT/root/setup-rootfs-session.sh"
env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	LINUX_USER="$LINUX_USER" \
	LINUX_HOSTNAME="$LINUX_HOSTNAME" \
	LINUX_DESKTOP="$DESKTOP" \
	LINUX_ROOT_LABEL="$ROOT_LABEL" \
	LINUX_SCALE="$SCALE" \
	LINUX_USER_PASSWORD="${LINUX_USER_PASSWORD:-}" \
	chroot "$OUT" /root/setup-rootfs-session.sh >>"$LOG_FILE" 2>&1
rm -f "$OUT/root/setup-rootfs-session.sh"

# Конфигурация, не содержащая пользовательских данных, для рабочего образа.
if [ -f "$ROOT/patches/systemd/phosh-dreamlte.conf" ]; then
	mkdir -p "$OUT/etc/systemd/system/phosh.service.d"
	cp "$ROOT/patches/systemd/phosh-dreamlte.conf" \
		"$OUT/etc/systemd/system/phosh.service.d/dreamlte.conf"
fi
if [ -f "$ROOT/patches/systemd/dreamlte-usbnet.sh" ]; then
	mkdir -p "$OUT/etc/NetworkManager/conf.d"
	mkdir -p "$OUT/etc/systemd/system/sysinit.target.wants"
	install -m 0755 "$ROOT/patches/systemd/dreamlte-usbnet.sh" \
		"$OUT/usr/local/sbin/dreamlte-usbnet"
	install -m 0644 "$ROOT/patches/systemd/dreamlte-usbnet.service" \
		"$OUT/etc/systemd/system/dreamlte-usbnet.service"
	install -m 0644 "$ROOT/patches/systemd/dreamlte-usbnet-nm.conf" \
		"$OUT/etc/NetworkManager/conf.d/dreamlte-usbnet.conf"
	ln -sf ../dreamlte-usbnet.service \
		"$OUT/etc/systemd/system/sysinit.target.wants/dreamlte-usbnet.service"
fi

if [ -n "$KERNEL_TREE" ]; then
	KERNEL_TREE="$(readlink -f "$KERNEL_TREE")"
	[ -d "$KERNEL_TREE" ] || { echo "нет kernel tree: $KERNEL_TREE" >&2; exit 1; }
	echo ">> устанавливаю модули ядра"
	make -C "$KERNEL_TREE" INSTALL_MOD_PATH="$OUT" INSTALL_MOD_STRIP=1 modules_install \
		>>"$LOG_FILE" 2>&1
	find "$OUT/lib/modules" -type l -delete 2>/dev/null || true
fi

# В чистом образе не должно остаться идентификатора сборочной машины,
# временных apt-файлов, ключей хоста или журналов текущей сессии.
rm -f "$OUT/etc/machine-id" "$OUT/var/lib/dbus/machine-id"
mkdir -p "$OUT/etc"
touch "$OUT/etc/machine-id"
cat > "$OUT/etc/resolv.conf" <<'EOF'
# DNS is managed by NetworkManager after boot; these public fallbacks keep
# the freshly installed system usable before that first connection.
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
rm -rf "$OUT/var/cache/apt/archives/"*
rm -rf "$OUT/var/lib/apt/lists/"*
find "$OUT/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -f "$OUT/usr/sbin/policy-rc.d"
rm -f "$OUT/usr/bin/qemu-aarch64-static"
sync

echo ">> очищаю временные данные и упаковываю образ"
tar --numeric-owner --xattrs --acls \
	--exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
	--exclude='./tmp/*' --exclude='./root/.bash_history' \
	-C "$OUT" -czf "$ARCHIVE" . >>"$LOG_FILE" 2>&1
sha256sum "$ARCHIVE"
echo "=== clean Debian rootfs готов ==="
echo "Архив: $ARCHIVE"
echo "Журнал: $LOG_FILE"
