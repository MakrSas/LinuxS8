#!/bin/bash
# Готовит Debian-rootfs к первому НАСТОЯЩЕМУ запуску systemd на устройстве.
#
# Запускается ВНУТРИ chroot в этот rootfs (из TWRP, нативно — эмуляция не
# нужна, TWRP это тот же arm64 Linux с полным root).
#
# Главное соображение, из которого следует всё остальное: у загруженной
# нашим ядром системы нет ни USB, ни сети — узла USB-контроллера в mainline
# DT для Exynos8895 нет вообще. Значит там не будет ни adb, ни ssh, ни
# внешней клавиатуры. Единственный ввод — тачскрин и кнопки, единственный
# вывод — экран. Поэтому:
#   * журнал должен писаться на саму карту, иначе после неудачи его неоткуда
#     будет взять (только этот файл и расскажет, что пошло не так);
#   * вход должен быть автоматическим — набрать пароль физически нечем;
#   * всё, что ждёт сеть, надо выключить, иначе загрузка встанет в таймаут.
set -euo pipefail

LINUX_USER="${LINUX_USER:-phone}"
LINUX_HOSTNAME="${LINUX_HOSTNAME:-dreamlte}"
LINUX_DESKTOP="${LINUX_DESKTOP:-phosh}"
LINUX_ROOT_LABEL="${LINUX_ROOT_LABEL:-linuxroot}"
LINUX_SCALE="${LINUX_SCALE:-3}"
LINUX_USER_PASSWORD="${LINUX_USER_PASSWORD:-}"

case "$LINUX_DESKTOP" in
	phosh|gnome) ;;
	*) echo 'LINUX_DESKTOP must be phosh or gnome' >&2; exit 1 ;;
esac
case "$LINUX_SCALE" in
	1|2|3|4) ;;
	*) echo 'LINUX_SCALE must be an integer from 1 to 4' >&2; exit 1 ;;
esac

if [ -z "$LINUX_USER_PASSWORD" ]; then
	if [ -t 0 ]; then
		printf 'Password for %s: ' "$LINUX_USER" >&2
		read -r -s LINUX_USER_PASSWORD
		printf '\n' >&2
	else
		echo 'LINUX_USER_PASSWORD is required in a non-interactive chroot' >&2
		exit 1
	fi
fi

if [ -z "$LINUX_USER_PASSWORD" ]; then
	echo 'the Linux user password must not be empty' >&2
	exit 1
fi

# --- 1. Журнал на диск -------------------------------------------------
# Storage=auto пишет на диск только если каталог уже существует, поэтому
# и каталог, и явная настройка.
mkdir -p /var/log/journal
if grep -qE '^#?Storage=' /etc/systemd/journald.conf; then
	sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
else
	printf '\n[Journal]\nStorage=persistent\n' >> /etc/systemd/journald.conf
fi

# --- 2. fstab ----------------------------------------------------------
# Корень уже смонтирован initramfs'ом, но systemd-remount-fs и fsck хотят
# видеть запись. Метка, а не /dev/mmcblk0p1: номер устройства зависит от
# того, что ядро увидит на этой загрузке.
#
# passno = 0, а не 1: e2fsprogs в этот rootfs не ставился (debootstrap
# --variant=minbase его не тянет, gnome-core тоже), так что fsck.ext4 в
# системе просто нет — с passno=1 systemd-fsck-root уйдёт в ошибку на каждой
# загрузке. Проверять карту всё равно есть чем из TWRP.
cat > /etc/fstab <<'EOF'
LABEL=__LINUX_ROOT_LABEL__  /      ext4  defaults,noatime  0  0
tmpfs           /tmp   tmpfs mode=1777,nosuid,nodev  0  0
EOF
sed -i "s/__LINUX_ROOT_LABEL__/$LINUX_ROOT_LABEL/" /etc/fstab

# --- 3. Имя машины -----------------------------------------------------
echo "$LINUX_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1	localhost
127.0.1.1	__LINUX_HOSTNAME__
::1		localhost ip6-localhost ip6-loopback
EOF
sed -i "s/__LINUX_HOSTNAME__/$LINUX_HOSTNAME/" /etc/hosts

# --- 4. Обычный пользователь -------------------------------------------
# GDM не пускает root в графический сеанс, так что нужен обычный аккаунт.
# Группы добавляем только те, что реально существуют, — useradd падает
# целиком, если хоть одной нет.
GROUPS_WANTED="sudo video input audio render plugdev netdev"
GROUPS_OK=""
for g in $GROUPS_WANTED; do
	if getent group "$g" >/dev/null; then
		GROUPS_OK="${GROUPS_OK:+$GROUPS_OK,}$g"
	fi
done
if ! id "$LINUX_USER" >/dev/null 2>&1; then
	if [ -n "$GROUPS_OK" ]; then
		useradd -m -s /bin/bash -G "$GROUPS_OK" "$LINUX_USER"
	else
		useradd -m -s /bin/bash "$LINUX_USER"
	fi
fi
printf '%s:%s\n' "$LINUX_USER" "$LINUX_USER_PASSWORD" | chpasswd
passwd -l root >/dev/null 2>&1 || true

# Host keys must be unique per installation.  Never copy the keys from the
# build host or from another phone into a public/rootfs template.
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
ssh-keygen -A >/dev/null 2>&1 || true

# --- 5. Автовход / оболочка ---------------------------------------------
# Файл переписывается целиком, а не патчится: в стоковом daemon.conf те же
# строки уже присутствуют закомментированными, поэтому любая проверка вида
# "есть ли там AutomaticLoginEnable" срабатывает на комментарий и тихо
# ничего не делает (наступили на это с первого раза).
if [ "$LINUX_DESKTOP" = gnome ] && [ -d /etc/gdm3 ]; then
cat > /etc/gdm3/daemon.conf <<'EOF'
# GDM configuration storage
#
# See /usr/share/gdm/gdm.schemas for a list of available options.

[daemon]
# Пароль набрать физически нечем — клавиатуры у этого устройства нет,
# а экранная появляется только внутри уже запущенного сеанса GNOME.
AutomaticLoginEnable = true
AutomaticLogin = __LINUX_USER__

# Xorg не установлен (ставили с --no-install-recommends), в
# /usr/share/wayland-sessions лежит только gnome — то есть сеанс в любом
# случае Wayland, запасного пути через X нет.
WaylandEnable = true

[security]

[xdmcp]

[chooser]

[debug]
# Включено намеренно: понять, почему сеанс не стартовал, можно будет только
# по журналу на карте — другого канала диагностики у нас нет.
Enable = true
EOF
sed -i "s/__LINUX_USER__/$LINUX_USER/" /etc/gdm3/daemon.conf
fi

# --- 5a. Масштаб интерфейса --------------------------------------------
# У simpledrm нет EDID, поэтому GNOME/phoc не могут надёжно сохранить
# настройку из графического диалога. Записываем целое значение в чистый
# образ заранее. Значение 3 соответствует 300%% и оставляет на экране
# 480 логических пикселей по ширине — это минимально удобный режим для
# текущего 1440x2960 дисплея.
if [ "$LINUX_DESKTOP" = phosh ]; then
	mkdir -p /etc/phosh
	PHOC_MARK='# --- dreamlte-installer-scale ---'
	if [ -f /etc/phosh/phoc.ini ]; then
		sed -i "/^$PHOC_MARK/,\$d" /etc/phosh/phoc.ini
	fi
	cat >> /etc/phosh/phoc.ini <<EOF
$PHOC_MARK
[output:Unknown-1]
scale = $LINUX_SCALE
EOF
else
	mkdir -p /etc/dconf/db/local.d
	cat > /etc/dconf/db/local.d/01-dreamlte-scale <<EOF
[org/gnome/desktop/interface]
scaling-factor=uint32 $LINUX_SCALE
EOF
	if command -v dconf >/dev/null 2>&1; then
		dconf update || true
	fi
fi

# --- 6. Цель по умолчанию ----------------------------------------------
systemctl set-default graphical.target
mkdir -p /etc/systemd/system/graphical.target.wants
if [ "$LINUX_DESKTOP" = phosh ]; then
	rm -f /etc/systemd/system/graphical.target.wants/gdm3.service
	ln -sf /usr/lib/systemd/system/phosh.service \
		/etc/systemd/system/graphical.target.wants/phosh.service
else
	rm -f /etc/systemd/system/graphical.target.wants/phosh.service
fi

# --- 7. Выключить всё, что ждёт сеть или диск --------------------------
# Без этого загрузка упирается в таймауты по 90-120 секунд на каждом.
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
systemctl mask   NetworkManager-wait-online.service 2>/dev/null || true
systemctl mask   systemd-networkd-wait-online.service 2>/dev/null || true
systemctl disable e2scrub_all.timer 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable man-db.timer 2>/dev/null || true

# --- 8. Часы -----------------------------------------------------------
# RTC в mainline для этого устройства нет, система стартует из 1970-го.
# systemd-timesyncd умеет подтягивать время вперёд из этого файла, даже
# когда сети нет, — этого достаточно, чтобы не было "timestamp in the
# future" на каждом файле и чтобы журнал был читаемым.
mkdir -p /var/lib/systemd/timesync
touch /var/lib/systemd/timesync/clock
systemctl enable systemd-timesyncd.service 2>/dev/null || true

# --- 9. Не тянуть GDM в бесконечный перезапуск -------------------------
# Если gnome-shell не заведётся, GDM по умолчанию перезапускается вечно и
# затирает экран, не давая ничего прочитать. Пусть сдаётся.
mkdir -p /etc/systemd/system/gdm3.service.d
cat > /etc/systemd/system/gdm3.service.d/no-restart.conf <<'EOF'
[Service]
Restart=no
EOF

# --- 10. Рендеринг -----------------------------------------------------
# Phosh рисует на Mali-G71 через panfrost (Mesa из trixie-backports), вывод —
# SimpleDRM. GTK4-отрисовщик ngl на Bifrost v6 даёт пустые окна, поэтому
# GTK4 — через cairo (см. docs/HANDOFF.md).
# GNOME/mutter с panfrost рядом с SimpleDRM падает, поэтому для него — llvmpipe.
if [ "$LINUX_DESKTOP" = phosh ]; then
	cat > /etc/environment <<'EOF'
GSK_RENDERER=cairo
EOF
else
	cat > /etc/environment <<'EOF'
LIBGL_ALWAYS_SOFTWARE=1
GALLIUM_DRIVER=llvmpipe
GSK_RENDERER=cairo
EOF
	mkdir -p /etc/systemd/system/gdm3.service.d
	cat > /etc/systemd/system/gdm3.service.d/software-gl.conf <<'EOF'
[Service]
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=GALLIUM_DRIVER=llvmpipe
EOF
fi

# --- 11. Дать GNOME Shell время подняться -------------------------------
# systemd убивает org.gnome.Shell@wayland.service, если тот не отчитался о
# готовности за 90 секунд по умолчанию:
#
#   org.gnome.Shell@wayland.service: start operation timed out. Terminating.
#
# На llvmpipe при 1440x2960 первый кадр рисует процессор, и в 90 секунд это
# укладывается далеко не всегда — особенно когда параллельно идёт опыт с
# mdelay-маркерами в ядре и посекундной синхронизацией на карту. Сеанс при
# этом полностью исправен, его просто не дожидаются.
mkdir -p /etc/systemd/user/org.gnome.Shell@wayland.service.d
cat > /etc/systemd/user/org.gnome.Shell@wayland.service.d/timeout.conf <<'EOF'
[Service]
TimeoutStartSec=600
EOF

# --- 12. Резервная консоль ---------------------------------------------
# Печатать в неё некому и набрать в ней нечего (клавиатуры нет), но если
# GDM не стартует, живой getty на экране — это хотя бы признак того, что
# сама система дошла до multi-user.
systemctl enable getty@tty1.service 2>/dev/null || true

sync
echo "=== setup-rootfs-session.sh done ==="
