# Debian + GNOME на Samsung Galaxy S8 (SM-G950F)

Проект по установке Debian (arm64) с графическим ускорением и рабочим столом GNOME
на Samsung Galaxy S8 (SM-G950F, Exynos 8895 / Mali-G71 MP20).

## Цель

- Полноценный Debian на телефоне.
- Аппаратное графическое ускорение (Mali-G71, драйвер Panfrost/Mesa).
- Рабочий стол GNOME (GNOME Shell / Mutter, Wayland).

## Текущий статус (актуально на 2026-08-07)

- 🎉 **Mainline-ядро Linux (7.2.0-rc6) успешно загружается на реальном
  устройстве** через uniLoader — initramfs стартует, лог загрузки виден на
  экране телефона через DRM/SimpleDRM. Тачскрин и кнопки (GPIO-keys) —
  подтверждённо рабочие. Подробности — см.
  [docs/progress-log.md](docs/progress-log.md).
- 🎉 **Debian 13 (trixie) arm64 реально работает на телефоне** — debootstrap
  (обе стадии) пройден нативно через chroot в TWRP. `/bin/bash`, `dpkg`,
  `apt` работают.
- 🎉🎉 **Рабочий стол GNOME 48 запускается на телефоне.** Полная цепочка без
  единого проприетарного блоба: `S-Boot → uniLoader → mainline 7.2.0-rc6 →
  initramfs → switch_root → systemd 257 → GDM (автовход) → GNOME Shell 48.7
  на Wayland`. Рендеринг пока **программный** (llvmpipe): GPU не подключён,
  это и есть оставшаяся часть цели.
- **Прямой интернет в TWRP без сети на телефоне:** `adb reverse` +
  `tinyproxy` на хосте — TCP-туннель поверх adb-канала, `apt` внутри chroot
  ходит в реальный интернет напрямую. Заменил медленную qemu-эмуляцию для
  установки пакетов.
- 🎉 **Debian грузится с microSD нашим собственным ядром** — `switch_root`
  проходит, rootfs с карты исполняется как корневая ФС. Карта работает в
  high-speed на 50 МГц. Корневая причина многодневной проблемы «карта
  опознаётся, но чтение всегда падает с DRTO» — ошибка кодирования таймаута
  данных для Exynos8895 в `dw_mmc`: `TMOUT[10:8]` там множитель, а не
  младшие биты счётчика. Патчи — в [patches/kernel/](patches/kernel/).
- 🎉 **Внутренняя память (UFS) заработала на полной скорости** — HS Gear 3,
  две линии, серия B; накопитель Samsung KLUCG4J1ED-B0C1 на 64 ГБ,
  `sda1`…`sda29` видны, разделы читаются. Понадобились: свой PHY-драйвер
  `samsung,exynos8895-ufs-phy` с калибровкой PMA из вендорского dts, своя
  последовательность старта линка, флаг `EXYNOS_UFS_OPT_UFSPR_SECURE`
  против SError на защищённом UFSP, `freq-table-hz` (без него все тайминги
  M-PHY считались от нулевой частоты) и чтение статуса смены режима питания
  из регистра UniPro `0x78EC` вместо несуществующего поля в `HCS`. Разбор —
  в [docs/ufs-bringup.md](docs/ufs-bringup.md).
- **У загруженной системы нет USB и сети** (узла USB-контроллера в mainline
  DT нет вообще, WiFi не поднят): ни `adb`, ни внешней клавиатуры, ни `apt`.
  Ввод — тачскрин и кнопки, вывод — экран. Всё готовится заранее из TWRP.
- USERDATA (34.5GB, раньше FAT32 от попыток с Windows) переформатирован под
  ext4 — постоянное хранилище для Linux-rootfs.
- Родной раздел BOOT сохранён локально перед перепрошивкой
  (`build/device-backups/boot_orig.img`) — путь отката есть.
- GPU: Mali-G71 официально не поддерживается драйвером Panfrost. Решение
  принято — делаем bring-up Panfrost для G71 сами (не идём через
  Halium/libhybris, хотя рабочий заброшенный порт для этого устройства и
  существует) — обоснование см.
  [docs/risks-and-open-questions.md](docs/risks-and-open-questions.md#1-решено-2026-08-06-идём-через-bring-up-panfrost-для-mali-g71-не-через-halium)
  и [docs/graphics.md](docs/graphics.md).
- Следующий практический шаг: перенести Debian с microSD на `sda29`
  (USERDATA, 34.5 ГБ). Для этого UFS и PHY должны подниматься до
  монтирования корня — сейчас они модули в blacklist. После этого —
  bring-up Panfrost для Mali-G71 (единственное, что отделяет проект от
  исходной цели целиком). Побочные направления: WiFi, USB-контроллер, звук.

## Документация

- [docs/device.md](docs/device.md) — железо и текущее состояние устройства.
- [docs/prior-art.md](docs/prior-art.md) — что уже сделано сообществом (mainline-ядро, uniLoader, postmarketOS, Halium).
- [docs/boot-chain.md](docs/boot-chain.md) — план загрузки (uniLoader + mainline, запасные варианты).
- [docs/graphics.md](docs/graphics.md) — план по графическому ускорению (Mali-G71/Panfrost) и открытый блокер.
- [docs/risks-and-open-questions.md](docs/risks-and-open-questions.md) — открытые риски и вопросы.
- [docs/NEXT-SESSION.md](docs/NEXT-SESSION.md) — **промпт для продолжения работы в новой сессии** и чек-лист.
- [docs/ufs-bringup.md](docs/ufs-bringup.md) — **bring-up внутренней памяти (UFS): состояние, что исправлено, что делать дальше.** Самодостаточный документ для продолжения работы.
- [docs/progress-log.md](docs/progress-log.md) — журнал прогресса по датам.

## Структура репозитория

```
.
├── docs/           # документация проекта
├── patches/        # наши изменения к mainline-ядру + скрипты initramfs/rootfs
├── configs/        # конфиг ядра (savedefconfig)
├── scripts/        # скрипты сборки/прошивки (будут добавляться по ходу работы)
├── rootfs/         # (не в git) debootstrap rootfs
├── firmware/       # (не в git) прошивки/блобы с устройства
├── images/         # (не в git) образы разделов, бэкапы TWRP
└── build/          # (не в git) артефакты сборки ядра/GRUB
```

Папки `rootfs/`, `firmware/`, `images/`, `backups/`, `downloads/`, `build/`
создаются локально по мере работы и не должны попадать в публичный
репозиторий (см. [.gitignore](.gitignore)) — там будут большие бинарники,
дампы устройства и потенциально проприетарные блобы.

## Открытие кода

Планируется открыть репозиторий публично после того, как появится рабочий
результат. TODO перед паблишем:
- [ ] выбрать лицензию;
- [ ] проверить, что в истории git и в рабочих папках нет проприетарных
      блобов/ключей, которые нельзя распространять;
- [ ] актуализировать этот README.
