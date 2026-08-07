# Bring-up UFS на dreamlte (SM-G950F, Exynos8895)

**Цель:** отвязаться от microSD — чтобы Debian жил на внутренней памяти
телефона (34.5 ГБ), а не на карте.

Документ самодостаточный: по нему можно продолжить работу с нуля, не читая
переписку. Журнал по датам — в [progress-log.md](progress-log.md).

---

## 1. Где мы сейчас

| Что | Состояние |
|---|---|
| Debian 13 + GNOME 48 | **работает**, грузится с microSD (`mmcblk0p1`, метка `userdata`) |
| Внутренняя память (UFS) | **не работает** — линк UniPro не поднимается |
| Ядро | mainline 7.2.0-rc6, база `0d8395707`, дерево в `build/src/linux` |
| Прошито в BOOT (`sda7`) | `build/device-backups/boot_freqtable.img` |
| UFS/PHY в ядре | модулями (`=m`), в blacklist, сами не грузятся |

Цепочка загрузки: `S-Boot → uniLoader → mainline → initramfs → switch_root →
systemd → GDM → GNOME`. Ядро S-Boot читает с внутренней UFS (у него свой
драйвер), корневая ФС — с карты.

---

## 2. Что уже исправлено (обе правки годятся в апстрим)

### 2.1. Паника от SError на защищённом UFSP

`exynos_ufs_config_smu()` пишет в блок защиты UFS. На Exynos8895 он
принадлежит защищённому миру: чтение из EL1 отдаёт нули, **запись поднимает
асинхронный внешний аборт**, ядро паникует и гасит остальные ядра.

```
SError Interrupt on CPU5, code 0x00000000bf000002
pc : exynos_ufs_config_smu+0xc0/0xe8 [ufs_exynos]
Kernel panic - not syncing: Asynchronous SError Interrupt
SMP: stopping secondary CPUs
```

Именно это годами выглядело как «телефон намертво завис в случайном месте»:
вывод паники не успевал дойти до fbcon.

**Правка:** свой `exynos8895_ufs_drvs` в `drivers/ufs/host/ufs-exynos.c` с
флагом `EXYNOS_UFS_OPT_UFSPR_SECURE` (заведён в апстриме ровно для этого,
его использует `gs101`) и compatible `samsung,exynos8895-ufs`.

### 2.2. Отсутствие `freq-table-hz` обнуляло все тайминги M-PHY

`ufshcd_parse_clock_info()` без этого свойства выходит **раньше**, чем
добавит в `hba->clk_list_head` хоть один клок:

```c
sz = of_property_count_u32_elems(np, "freq-table-hz");
if (sz <= 0) {
	dev_info(dev, "freq-table-hz property not specified\n");
	goto out;          /* список остаётся ПУСТЫМ */
}
```

Дальше: `exynos_ufs_get_clk_info()` видит пустой список, уходит по `goto out`
и возвращает **0, то есть успех**, оставив `pclk_rate` и `mclk_rate` нулями.
На arm64 деление на ноль не ловится, а тихо даёт ноль — период стал нулевым,
делитель PWM не нашёлся, и все тайминги M-PHY посчитались от нулевой
частоты.

**Правка:** `freq-table-hz = <0 0>, <0 0>;` в узел `ufs` (так у `exynos7`,
`exynosautov9`, `exynosautov920`, `gs101` — у **всех** in-tree узлов UFS).

Проверка, что подействовало: атрибуты в логе стали настоящими
(`0x317 val 0x28`, `0x355 val 0x1a`, `0x354 val 0x41`, `0x353 val 0x9a`)
вместо нулей, и пропала строка `failed to decide pwm clock divider`.

---

## 3. Что сломано сейчас

**UIC-интерфейс не оживает после того, как драйвер сбрасывает контроллер.**

```
UFSTRACE: hce_enable_notify status=0 / status=1     <- HCE проходит
UFSTRACE: link_startup_notify -> pre_link enter
dme-set: attr-id 0x9540 val 0x1 failed 0 retries    <- и дальше падает всё
UFSTRACE: exynos_ufs_phy_init -> phy_init -> power_on -> calibrate
uic cmd 0x16 with arg3 0x0 completion timeout        (0x16 = DME_LINK_STARTUP)
link startup failed -110
```

### Ключевое наблюдение

`HCS` **до** загрузки драйвера = `0x0000000f`:

| Бит | Имя | Значение |
|---|---|---|
| 0 | DP | устройство подключено |
| 1 | UTRLRDY | очередь запросов готова |
| 2 | UTMRLRDY | очередь задач готова |
| 3 | **UCRDY** | **UIC-интерфейс готов** |

Регистры PMA самого PHY при этом держат осмысленные значения (`0x88`, `0x88`).

**S-Boot оставляет контроллер и PHY полностью настроенными, с поднятым
линком** — он же только что прочитал через них ядро. Железо исправно.
Ломается оно ровно тогда, когда наш драйвер сбрасывает контроллер и
поднимает линк заново по сценарию от Exynos7420.

---

## 4. Что делать дальше (по убыванию приоритета)

### 4.1. Настоящий PHY-драйвер под Exynos8895

Сейчас в dts стоит шаблон `samsung,exynos7-ufs-phy`, а это другой чип
(Exynos7420). Конкретно нужно:

- **Своя таблица калибровки** из даунстрима. Мы используем
  `exynos7_ufs_phy_cfgs` из `drivers/phy/samsung/phy-exynos7-ufs.c` — набор
  магических чисел, посчитанный под 7420.
- **Смещение регистра изоляции в PMU.** У нас `0x724` (из даунстрима,
  `0x16480724` под узлом `ufs-phy-sys`), у драйвера по умолчанию `0x720`
  (регистр 7420). **Никем не проверено** — прочитать PMU из userspace не
  вышло (bus error), нужен другой способ.
- **Модель тактов.** У exynos7 их четыре (`tx0_symbol_clk`, `rx0_symbol_clk`,
  `rx1_symbol_clk`, `ref_clk`), у нас три из них — фиктивные `&oscclk`.
  Все Samsung SoC новее 7420 (autov9, autov920, gs101) используют **один**
  `ref_clk`. Проверено ранее: у Exynos8895 в даунстриме таких гейтов нет
  вообще, есть только 4 UFS-клока (aclk/fmp/unipro + мультиплексор).
  Вывод: четырёхтактовая модель для нас неверна изначально.

Источник даунстрима: `Dyneteve/android_kernel_samsung_universal8895`,
оттуда уже брались адреса регистров (подтвердились независимо).

### 4.2. Проверить, не мешают ли quirks от exynos7

`exynos8895_ufs_drvs` унаследовал `quirks`/`opts` от `exynos_ufs_drvs` целиком
(в том числе `UFSHCI_QUIRK_BROKEN_HCE`, `EXYNOS_UFS_OPT_SKIP_CONNECTION_ESTAB`,
`EXYNOS_UFS_OPT_USE_SW_HIBERN8_TIMER`). Осознанно: меняли одно за раз. Стоит
перебрать — особенно `EXYNOS_UFS_OPT_SKIP_CONFIG_PHY_ATTR`, который у всех
новых SoC выставлен, а у нас нет (именно он отключает те самые `dme-set`,
что сейчас падают пачками).

### 4.3. Мелкий отдельный дефект

Путь очистки после ошибки сам неисправен: `insmod` завершается по SIGSEGV, в
логе стек через `ufshcd_setup_clocks+0x100 → ufshcd_hba_exit → ufshcd_init`.
К молчанию UIC отношения не имеет, но чинить придётся.

---

## 5. Как работать с устройством

### 5.1. Цикл эксперимента

```bash
# телефон в TWRP
./scripts/arm-experiment.sh experiments/NN-имя.sh
./build/tools/platform-tools/adb reboot
# ждём загрузки; если завис — Power + Volume Down, зайти в TWRP
./scripts/collect-lab.sh
```

Флаг `ARMED` снимается **на устройстве до запуска** опыта — зависание не
превращается в петлю перезагрузок.

### 5.2. Пересборка и прошивка

```bash
./scripts/build-boot.sh <имя> --kernel   # ядро + dtb + МОДУЛИ + boot.img
./scripts/push-modules.sh                # обязательно! модули живут в rootfs
ADB=./build/tools/platform-tools/adb
$ADB push build/device-backups/boot_<имя>.img /tmp/b.img
$ADB shell 'dd if=/tmp/b.img of=/dev/block/sda7 bs=4096 && sync'
# сверить md5 обязательно:
$ADB shell 'dd if=/dev/block/sda7 bs=512 count=68992 2>/dev/null | md5sum'
```

### 5.3. Чтение логов

```bash
./scripts/read-journal.sh --list-boots
./scripts/read-journal.sh --boot=<id> -k -o short-monotonic | grep UFSTRACE
```

Перед каждым монтированием карты: `e2fsck -fp /dev/block/mmcblk0p1`
(после форс-ребутов ФС грязная).

---

## 6. Грабли, на которые уже наступали

- **Экран врёт.** Вывод printk отложен: при простое процессора уже
  напечатанные строки лежат невыведенными, пока не придёт прерывание
  (нажатие кнопки буквально «продолжает лог»). Последняя строка на экране —
  ни о чём. Верить только journal и ramoops.
- **`make Image dtbs` не собирает модули**, а `modules_install` их не
  пересобирает. Разложить старые `.ko` — значит полдня читать трассировку,
  которой в них нет. В `build-boot.sh` это уже исправлено.
- **Выкладывание модулей в rootfs меняет поведение загрузки:** udev видит
  OF-modalias у включённых в dts узлов и грузит их сам. UFS поэтому в
  blacklist (`/etc/modprobe.d/dreamlte-ufs.conf`), эксперименты используют
  `insmod` с явным путём.
- **Функция, возвращающая 0 при пустом списке, делает маркер «ok» ложным.**
  Наш `E8 get_clk_info ok` честно печатался, пока частоты были нулями.
- **`dev_info` о ненайденном свойстве — не пометка, а сообщение об обрыве
  разбора.** `freq-table-hz property not specified` висела в логе с первой
  удачной загрузки драйвера.
- **ramoops работает**, но данные появляются на **следующей** загрузке —
  не надо перезагружаться дважды подряд, иначе они теряются.
- **adb shell портит бинарные данные**, для чтения разделов только
  `adb exec-out`.
- **У загруженной системы нет ни USB, ни сети, ни клавиатуры** — всё
  готовится заранее из TWRP.

---

## 7. Аппаратные факты (проверены на устройстве)

```
UFS hci      0x11120000   CAP = 0x1303ff0f, VER = 0x00000210 (UFSHCI 2.1)
UFS vs_hci   0x11121100
UFS unipro   0x11110000
UFS ufsp     0x11130000   читается нулями — принадлежит защищённому миру
UFS PHY PMA  0x11124000
PMU          0x16480000   из userspace не читается (bus error)
IRQ                  334
core_clk         gout_fsys0_ufs_embd_i_aclk        166 562 500 Гц
sclk_unipro_main gout_fsys0_ufs_embd_i_clk_unipro  166 562 500 Гц
vcc              GPIO gpg0-0, active high (из даунстрим-debugfs)
```

`bootargs` содержат `clk_ignore_unused pd_ignore_unused` — без них ядро
гасит блоки FSYS0 на позднем этапе загрузки, и контроллер становится
полумёртвым (`CAP` читается нулём).
