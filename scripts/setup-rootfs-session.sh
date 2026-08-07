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
set -x

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
LABEL=userdata  /      ext4  defaults,noatime  0  0
tmpfs           /tmp   tmpfs mode=1777,nosuid,nodev  0  0
EOF

# --- 3. Имя машины -----------------------------------------------------
echo dreamlte > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1	localhost
127.0.1.1	dreamlte
::1		localhost ip6-localhost ip6-loopback
EOF

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
if ! id phone >/dev/null 2>&1; then
	useradd -m -s /bin/bash -G "$GROUPS_OK" phone
fi
echo 'phone:phone' | chpasswd
echo 'root:root' | chpasswd

# --- 5. Автовход в GNOME -----------------------------------------------
# Файл переписывается целиком, а не патчится: в стоковом daemon.conf те же
# строки уже присутствуют закомментированными, поэтому любая проверка вида
# "есть ли там AutomaticLoginEnable" срабатывает на комментарий и тихо
# ничего не делает (наступили на это с первого раза).
cat > /etc/gdm3/daemon.conf <<'EOF'
# GDM configuration storage
#
# See /usr/share/gdm/gdm.schemas for a list of available options.

[daemon]
# Пароль набрать физически нечем — клавиатуры у этого устройства нет,
# а экранная появляется только внутри уже запущенного сеанса GNOME.
AutomaticLoginEnable = true
AutomaticLogin = phone

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

# --- 6. Цель по умолчанию ----------------------------------------------
systemctl set-default graphical.target

# --- 7. Выключить всё, что ждёт сеть или диск --------------------------
# Без этого загрузка упирается в таймауты по 90-120 секунд на каждом.
systemctl disable NetworkManager-wait-online.service 2>/dev/null
systemctl mask   NetworkManager-wait-online.service 2>/dev/null
systemctl mask   systemd-networkd-wait-online.service 2>/dev/null
systemctl disable e2scrub_all.timer 2>/dev/null
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null
systemctl disable man-db.timer 2>/dev/null

# --- 8. Часы -----------------------------------------------------------
# RTC в mainline для этого устройства нет, система стартует из 1970-го.
# systemd-timesyncd умеет подтягивать время вперёд из этого файла, даже
# когда сети нет, — этого достаточно, чтобы не было "timestamp in the
# future" на каждом файле и чтобы журнал был читаемым.
mkdir -p /var/lib/systemd/timesync
touch /var/lib/systemd/timesync/clock
systemctl enable systemd-timesyncd.service 2>/dev/null

# --- 9. Не тянуть GDM в бесконечный перезапуск -------------------------
# Если gnome-shell не заведётся, GDM по умолчанию перезапускается вечно и
# затирает экран, не давая ничего прочитать. Пусть сдаётся.
mkdir -p /etc/systemd/system/gdm3.service.d
cat > /etc/systemd/system/gdm3.service.d/no-restart.conf <<'EOF'
[Service]
Restart=no
EOF

# --- 10. Программный рендеринг -----------------------------------------
# GPU (Mali-G71) не поддержан ничем: Panfrost его не знает, а собственного
# драйвера нет. Единственный экран — SimpleDRM. Явно просим llvmpipe, чтобы
# Mesa не пыталась искать железный драйвер и не падала в неожиданном месте.
cat > /etc/environment <<'EOF'
LIBGL_ALWAYS_SOFTWARE=1
GALLIUM_DRIVER=llvmpipe
EOF
mkdir -p /etc/systemd/system/gdm3.service.d
cat > /etc/systemd/system/gdm3.service.d/software-gl.conf <<'EOF'
[Service]
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=GALLIUM_DRIVER=llvmpipe
EOF

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
systemctl enable getty@tty1.service 2>/dev/null

sync
echo "=== setup-rootfs-session.sh done ==="
