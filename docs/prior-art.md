# Существующие наработки сообщества (на 2026-08-06)

Ниже — то, что уже сделано другими для Samsung Galaxy S8 / Exynos 8895, без
привязки к какому-либо стороннему UEFI-проекту. Это меняет приоритеты плана
загрузки (см. [boot-chain.md](boot-chain.md)).

## 1. Mainline-ядро kernel.org — минимальная поддержка Exynos8895/SM-G950F

В основную ветку Linux (kernel.org) в 2024 году был принят патчсет
"Add minimal Exynos8895 SoC and SM-G950F support" (автор Ivo Ivanov,
несколько ревизий v1–v5, финальная версия — октябрь 2024).

Что вошло:
- Биндинги CPU (Samsung Mongoose M2), pinctrl, PMU, device tree для SoC и
  платы S8 (dreamlte).
- Достаточно для загрузки в минимальный initramfs shell: CPU, pinctrl,
  GPIO, simple-framebuffer, pstore.

Чего **нет** в mainline пока:
- Тачскрин, зарядка, звук, камеры, WiFi/BT, GPS, магнитометр, light/proximity
  сенсоры, барометр — по компонентной таблице на postmarketOS wiki
  большинство периферии ещё не портировано (см. ниже).
- GPU-драйвер — Mali-G71 отдельная история, см. [graphics.md](graphics.md).

Источники:
- [PATCH v5 00/10] Add minimal Exynos8895 SoC and SM-G950F support —
  https://lists.infradead.org/pipermail/linux-arm-kernel/2024-October/965497.html
- Barebox: ARM boards: add support for Samsung Galaxy S8 (dreamlte) —
  https://www.mail-archive.com/barebox@lists.infradead.org/msg54181.html

## 2. uniLoader — вторичный загрузчик для обхода Samsung S-Boot

Репозиторий: https://github.com/ivoszbg/uniLoader (автор тот же — ivoszbg).

- Минималистичный загрузчик, который упаковывает mainline-ядро + DTB +
  initramfs и прыгает в них, обходя проприетарный, незаменяемый Samsung
  S-Boot.
- Явно поддерживает dreamlte (в репо есть `exynos8895-dreamlte.dtb` и
  примеры сборки под это устройство).
- Активно используется как штатный способ загрузки mainline-ядра на этом
  устройстве (указан как "Secondary bootloader" на postmarketOS wiki).
- Поддерживает ARMv7 и ARMv8, сборка через обычный
  `make ARCH=... CROSS_COMPILE=...`.

**Это готовый, конкретный, актуальный для нашего устройства путь загрузки —
не требует стороннего UEFI и ожидания чужих исходников.**

## 3. postmarketOS — реальный, но ограниченный порт (downstream-ядро)

Wiki: https://wiki.postmarketos.org/wiki/Samsung_Galaxy_S8_(samsung-dreamlte)

- Использует **downstream** Android-ядро (4.4.111), не mainline. Готовых
  образов нет, ставится через `pmbootstrap` + TWRP-flashable zip.
- Что работает: экран, тачскрин, батарея, WiFi, USB OTG (с оговорками — USB
  клавиатура не работает в Xfce, но работает в SXMO).
- Что сломано: **3D-ускорение, звук, камера, Bluetooth, GPS, звонки/SMS/
  мобильный интернет.**
- Протестированные DE/WM: Weston, Xfce4, MATE, LXQt, Sxmo-de-dwm — **GNOME
  в заметке помечен как "no longer works"** (раньше запускался, сейчас нет).
- Есть таблица драйверов по железу — экран/тачскрин/акселерометр работают
  в mainline-варианте, но зарядка, звук, камеры, WiFi/BT, GPS, часть
  сенсоров — ещё нет.

## 4. Halium-порт (libhybris) — работает, но заброшен с 2022

- https://github.com/Halium/projectmanagement/issues/292
- Через libhybris (проброс Android HAL) — на момент последнего апдейта
  (2022-04-08) работали GPS, экран, лампочки, вибро, WiFi, сенсоры, звук,
  камера, ввод, NFC. USB требовал ручного костыля.
- Даёт доступ к проприетарному Android-графическому стеку (реальный,
  протестированный мост к GPU через vendor Mali blob), ценой отказа от
  "чистого" mainline DRM/KMS пути.
- Не обновлялся ~4 года — придётся многое проверять/чинить заново.
- **Важная оговорка (проверено 2026-08-06):** этот мост даёт GPU для
  Android-стороны (hwcomposer/EGL), но не для GNOME Shell/Mutter напрямую.
  Известные libhybris-компоузеры — Qt/qtmir (Ubuntu Touch) и заброшенный
  (с мая 2022) форк KWin `manjaro-libhybris/kwin-hybris`. Подключения
  Mutter к libhybris нигде не найдено — эту часть придётся делать с нуля.
  См. [graphics.md](graphics.md).

## Вывод: как это меняет план

- Не нужно ждать стороннего UEFI-донора, чтобы начать: uniLoader +
  mainline-ядро уже сегодня дают путь к загрузке Linux на этом железе.
- Самая большая проблема для цели проекта — не загрузка, а **GPU**: Panfrost
  официально не поддерживает Mali-G71 (см. [graphics.md](graphics.md)).
  Это сейчас главный блокер именно для "графического ускорения", а не boot
  chain.
- Halium/libhybris даёт рабочий (хоть и старый) мост к GPU через
  проприетарный blob, но **не готовое решение для GNOME** — компоузер
  (Mutter) к этому мосту ещё никто не подключал.
- **Решение (2026-08-06):** идём через bring-up Panfrost для G71 в mainline,
  не через Halium — подробности и обоснование в
  [graphics.md](graphics.md) и [risks-and-open-questions.md](risks-and-open-questions.md).
  Halium-порт остаётся задокументированным здесь как справочный материал.
