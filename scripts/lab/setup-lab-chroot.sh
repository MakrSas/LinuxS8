#!/bin/bash
# Ставит "лабораторию" в Debian на карте. Запускается ВНУТРИ chroot из TWRP.
set -x

# --- pstore ------------------------------------------------------------
# ramoops (reserved-memory@92000000 в dts) переживает тёплую перезагрузку,
# так что это единственный источник последних слов ядра, когда оно зависло
# и на диск ничего дописать уже не смогло. systemd-pstore при загрузке
# перекладывает содержимое в /var/lib/systemd/pstore и очищает область,
# освобождая её под следующий прогон.
grep -q '^pstore' /etc/fstab || \
	echo 'pstore  /sys/fs/pstore  pstore  defaults  0  0' >> /etc/fstab
systemctl enable systemd-pstore.service

# --- journald: писать сразу --------------------------------------------
# По умолчанию journald сбрасывает на диск раз в 5 минут; при зависании это
# ровно те 5 минут, которые нас и интересуют.
if grep -qE '^#?SyncIntervalSec=' /etc/systemd/journald.conf; then
	sed -i 's/^#\?SyncIntervalSec=.*/SyncIntervalSec=1s/' /etc/systemd/journald.conf
else
	sed -i '/^\[Journal\]/a SyncIntervalSec=1s' /etc/systemd/journald.conf
fi

# --- запретить udev грузить UFS самому ---------------------------------
# Как только модули легли в /lib/modules, udev увидел OF-modalias
# (of:N*T*Csamsung,exynos7-ufs) у включённых в dts узлов и загрузил их сам,
# на 11-й секунде загрузки — раньше, чем успел стартовать наш эксперимент.
# Телефон замёрз, а опыт даже не начался.
#
# Дальше UFS грузим только руками и только через insmod: modprobe honours
# эти строки, insmod — нет, поэтому эксперименту они не мешают.
cat > /etc/modprobe.d/dreamlte-ufs.conf <<'EOF'
# UFS на этом устройстве пока намертво вешает систему — грузить только
# осознанно, из эксперимента, через insmod с явным путём.
blacklist ufs_exynos
blacklist phy_exynos_ufs
install ufs_exynos /bin/true
install phy_exynos_ufs /bin/true
EOF

# --- юниты -------------------------------------------------------------
chmod 755 /root/lab/lab-runner.sh /root/lab/dreamlte-heartbeat.sh
mkdir -p /var/log/dreamlte
systemctl enable dreamlte-heartbeat.service
systemctl enable dreamlte-lab.service

# --- мелкий интерфейс --------------------------------------------------
# 1440x2960 на 5.8" это ~570 dpi; mutter выбрал масштаб 1 и всё вышло
# микроскопическим. Ставим системным умолчанием двукратный масштаб —
# пользователь при желании переопределит в Настройках, пользовательские
# значения dconf всё равно главнее системных.
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
cat > /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
cat > /etc/dconf/db/local.d/00-dreamlte-hidpi <<'EOF'
[org/gnome/desktop/interface]
scaling-factor=uint32 2
cursor-size=48

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']

[org/gnome/desktop/peripherals/touchscreen]
# Экранная клавиатура — единственный способ что-то набрать: физической
# клавиатуры нет, USB в mainline для этого чипа тоже нет.
EOF
cat > /etc/dconf/db/local.d/01-dreamlte-osk <<'EOF'
[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true
EOF
dconf update

sync
echo "=== setup-lab-chroot.sh done ==="
