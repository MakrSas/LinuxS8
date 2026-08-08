#!/usr/bin/env python3
"""Лаборатория dreamlte — пульт для опытов прямо с телефона.

Зачем: почти каждая проверка до сих пор стоила цикла «взвести опыт с
хоста — перезагрузиться — сходить в TWRP — забрать лог». Для вопросов
вида «а как это выглядит с другим отрисовщиком» это несоразмерно дорого.
Здесь то же самое делается нажатием пальца.

Почему GTK3, а не GTK4: приложения на GTK4 с отрисовщиком ngl на нашем
Mali-G71 рисуются сломанными — пропадают скругления, текст и всё, что
идёт через промежуточные буферы с масками. Пульт, написанный на GTK4,
сам оказался бы нечитаемым. GTK3 рисует содержимое процессором и
работает верно.

Права: запускать приложения можно от обычного пользователя, а смена
оболочки требует root — она идёт через маленький помощник
dreamlte-switch-shell, разрешённый в sudoers без пароля.
"""

import os
import re
import subprocess
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango  # noqa: E402

# Обработчик "draw" получает cairo.Context, а превращать его в объект
# Python умеет только пакет python3-gi-cairo. Без него страница кадров
# молча не рисовала бы ничего, сыпля TypeError в журнал — лучше сказать
# прямо. Остальные страницы от этого не зависят.
try:
    gi.require_foreign("cairo")
    HAVE_CAIRO = True
except Exception:  # noqa: BLE001
    HAVE_CAIRO = False

SHOTS = os.path.expanduser("~/Pictures/Screenshots")

# Приложения, которые имеет смысл гонять. Слева подпись, справа команда.
APPS = [
    ("Настройки", "gnome-control-center"),
    ("Калькулятор", "gnome-calculator"),
    ("Часы", "gnome-clocks"),
    ("Блокнот", "gnome-text-editor"),
    ("Магазин приложений", "gnome-software"),
    ("Браузер", "epiphany-browser"),
    ("Символы (эмодзи)", "gnome-characters"),
    ("Терминал (GTK3, контроль)", "gnome-terminal"),
]

# В GTK 4.18 opengl, ngl и gl — три имени одного и того же отрисовщика,
# так что по самому GSK выбор бинарный: ngl или cairo.
#
# Зато у panfrost есть рычаги, которыми можно попробовать заставить ngl
# работать. Два из них — прямые подозреваемые в нашей поломке:
#
#   nofp16  GTK4 рисует промежуточные буферы в половинной точности.
#           Если fp16 на Bifrost v6 хромает, картинка выйдет ровно такой,
#           как мы видим: пустые окна при целой геометрии.
#
#   nocrc   "transaction elimination" — Mali пропускает запись тайлов,
#           чьё содержимое не изменилось, сверяя контрольные суммы. Если
#           механизм врёт, тайлы не записываются, и остаются пустые
#           области.
#
#   linear  отключает тайловую раскладку текстур целиком. Грубо, зато
#           отсекает целый класс причин.
#
# Каждый вариант задаёт PAN_MESA_DEBUG целиком, а не дополняет: иначе
# непонятно, что именно проверяется.
RENDERERS = [
    ("ngl — как по умолчанию", {"GSK_RENDERER": "ngl"}),
    ("ngl без fp16", {"GSK_RENDERER": "ngl", "PAN_MESA_DEBUG": "nofp16"}),
    ("ngl без CRC-пропуска тайлов", {"GSK_RENDERER": "ngl", "PAN_MESA_DEBUG": "nocrc"}),
    ("ngl с линейными текстурами", {"GSK_RENDERER": "ngl", "PAN_MESA_DEBUG": "linear"}),
    ("ngl — всё сразу", {"GSK_RENDERER": "ngl",
                         "PAN_MESA_DEBUG": "nofp16,nocrc,linear,noafbc"}),
    # sync заставляет драйвер ждать каждое задание и падать на сбое GPU.
    # Медленно, зато если ngl упирается в аварию железа, она попадёт в
    # ~/lab-logs, а не растворится молча.
    ("ngl + ловить сбои GPU (sync)", {"GSK_RENDERER": "ngl",
                                      "PAN_MESA_DEBUG": "sync"}),
    ("cairo — процессором (заведомо целый)", {"GSK_RENDERER": "cairo"}),
]

SHELLS = [
    ("phosh — оболочка для телефона", "phosh"),
    ("GNOME — привычный рабочий стол", "gnome"),
]

FRAME_MODES = [
    ("весь экран", "full"),
    ("квадрат", "small"),
    ("заливка", "fill"),
]

# 1440x2960 на 5.8 дюйма — это около 570 dpi, поэтому без масштаба
# интерфейс нечитаемо мелкий. Логическая ширина при 3 равна 480 точкам,
# при 4 — 360, что для phosh нижняя граница.
# Узкое место оболочки — загрузка кадра клиента в текстуру GPU. Буфер
# GTK3 лежит построчно, текстуры Mali уложены тайлами, поэтому загрузка
# это перекладывание каждого пикселя процессором, а не копия. Замер:
# glmark2 (буфер GPU, загрузки нет) даёт 48-81 кадр/с на всю площадь,
# пульт в режиме заливки (буфер в памяти, работы для cairo почти нет) —
# только 20.
COMPOSITORS = [
    ("как сейчас — текстуры тайлами", "comp-default"),
    ("линейные текстуры — без перекладывания", "comp-linear"),
    ("композитинг процессором (сломает GTK4)", "comp-cpu"),
]

SCALES = [
    ("300% — целый (1440 → 480)", "scale3"),
    ("300% — дробный 3.075, как из настроек", "scale-frac"),
    ("400% — целый (1440 → 360)", "scale4"),
    ("200% — целый (1440 → 720)", "scale2"),
    ("100% — без масштаба", "scale1"),
]


def _find_label(widget):
    """Ищет метку внутри виджета, включая вложенные контейнеры."""
    if isinstance(widget, Gtk.Label):
        return widget
    if isinstance(widget, Gtk.Container):
        for child in widget.get_children():
            found = _find_label(child)
            if found is not None:
                return found
    return None


def big(widget, scale=1.4):
    """Крупный шрифт: экран 1440x2960 на 5.8 дюйма, иначе не попасть пальцем.

    Масштаб задаётся атрибутами Pango, а set_attributes есть только у
    Gtk.Label. Кнопки, радиокнопки и переключатель страниц метку прячут
    внутри, поэтому её надо найти. Первая версия звала set_attributes
    прямо на них — и пульт падал с AttributeError, не успев показаться.
    """
    label = _find_label(widget)
    if label is not None:
        attrs = Pango.AttrList()
        attrs.insert(Pango.attr_scale_new(scale))
        label.set_attributes(attrs)
    return widget


LOGDIR = os.path.expanduser("~/lab-logs")


def run_detached(cmd, env_extra=None):
    """Запуск без ожидания: пульт не должен блокироваться на приложении.

    Вывод пишется в ~/lab-logs/<имя>.log, а не в /dev/null. Раньше он
    терялся, и любой отказ приложения приходилось выяснять походом в TWRP
    за журналом — а это перезагрузка ради одной строчки.
    """
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    try:
        os.makedirs(LOGDIR, exist_ok=True)
        path = os.path.join(LOGDIR, os.path.basename(cmd[0]) + ".log")
        log = open(path, "w")
    except OSError:
        log = subprocess.DEVNULL
    try:
        subprocess.Popen(cmd, env=env, start_new_session=True,
                         stdout=log, stderr=subprocess.STDOUT)
        return None
    except Exception as exc:  # noqa: BLE001
        return str(exc)


def phoc_env():
    """Переменные, с которыми реально запущен композитор.

    Читаются из /proc, а не из конфигов: конфиг говорит, что мы хотели, а
    /proc — что получилось.
    """
    keep = ("PAN_MESA_DEBUG", "WLR_RENDERER", "WLR_DRM_DEVICES",
            "WLR_RENDER_DRM_DEVICE", "GSK_RENDERER")
    try:
        pid = subprocess.run(["pgrep", "-x", "phoc"], capture_output=True,
                             text=True, timeout=10).stdout.split()[0]
        with open(f"/proc/{pid}/environ", "rb") as fh:
            raw = fh.read().decode("utf-8", "replace")
    except Exception:  # noqa: BLE001
        return {"(не прочитать)": "phoc не найден или нет доступа"}
    out = {}
    for item in raw.split("\0"):
        k, _, v = item.partition("=")
        if k in keep:
            out[k] = v
    return out or {"(ничего из наших)": "переменные не заданы"}


def phoc_scale():
    try:
        with open("/etc/phosh/phoc.ini") as fh:
            tail = fh.read().rsplit("[output:Unknown-1]", 1)
        if len(tail) == 2:
            for ln in tail[1].splitlines():
                if ln.strip().startswith("scale"):
                    return ln.split("=", 1)[1].strip()
    except OSError:
        pass
    return "не задан"


def read_first(path, default="?"):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


class Lab(Gtk.Window):
    def __init__(self):
        super().__init__(title="Лаборатория dreamlte")
        self.set_default_size(720, 1400)
        self.renderer = dict(RENDERERS[0][1])
        self.renderer_name = RENDERERS[0][0]

        stack = self.stack = Gtk.Stack()
        stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)

        stack.add_titled(self._apps_page(), "apps", "Приложения")
        stack.add_titled(self._frames_page(), "frames", "Кадры")
        stack.add_titled(self._comp_page(), "comp", "Композитор")
        stack.add_titled(self._scale_page(), "scale", "Масштаб")
        stack.add_titled(self._log_page(), "logs", "Журнал")
        stack.add_titled(self._shell_page(), "shell", "Оболочка")
        stack.add_titled(self._info_page(), "info", "Состояние")

        # Не StackSwitcher: он выкладывает вкладки в одну строку, а страниц
        # семь. При масштабе 2 ему нужно больше, чем даёт экран, и последние
        # вкладки — "Оболочка" и "Состояние" — просто уезжали за край, где
        # до них было не дотянуться. Список влезает при любом масштабе.
        switcher = Gtk.ComboBoxText()
        for page in stack.get_children():
            switcher.append(stack.child_get_property(page, "name"),
                            stack.child_get_property(page, "title"))
        switcher.set_active(0)
        switcher.connect(
            "changed",
            lambda cb: stack.set_visible_child_name(cb.get_active_id()))
        for cell in switcher.get_cells():
            cell.set_property("scale", 1.3)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.pack_start(switcher, False, False, 6)
        box.pack_start(stack, True, True, 0)
        box.pack_start(self._status_bar(), False, False, 0)
        self.add(box)
        self.connect("destroy", Gtk.main_quit)

    # ---- общая строка состояния -------------------------------------
    def _status_bar(self):
        self.status = Gtk.Label(label="готово")
        self.status.set_line_wrap(True)
        self.status.set_xalign(0)
        self.status.set_margin_start(12)
        self.status.set_margin_end(12)
        self.status.set_margin_bottom(8)
        return big(self.status, 1.1)

    def say(self, text):
        self.status.set_text(text)

    # ---- страница приложений ----------------------------------------
    def _apps_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_start(12)
        box.set_margin_end(12)

        hint = Gtk.Label()
        hint.set_markup(
            "<b>Отрисовщик GTK4.</b> С ngl окна выходят пустыми: пропадают\n"
            "скругления, текст и полупрозрачные слои. cairo рисует верно, но\n"
            "процессором. Остальные варианты — попытки заставить ngl работать,\n"
            "отключая по одному механизму panfrost."
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        box.pack_start(big(hint, 1.0), False, False, 4)

        first = None
        for label, value in RENDERERS:
            btn = Gtk.RadioButton.new_with_label_from_widget(first, label)
            if first is None:
                first = btn
            btn.connect("toggled", self._on_renderer, value, label)
            box.pack_start(big(btn, 1.1), False, False, 0)

        box.pack_start(Gtk.Separator(), False, False, 6)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        for label, cmd in APPS:
            btn = Gtk.Button(label=label)
            btn.set_size_request(-1, 88)   # палец, а не мышь
            big(btn.get_child(), 1.3)
            btn.connect("clicked", self._on_launch, cmd, label)
            inner.pack_start(btn, False, False, 0)
        scroll.add(inner)
        box.pack_start(scroll, True, True, 0)
        return box

    def _on_renderer(self, btn, value, name):
        if btn.get_active():
            self.renderer = dict(value)
            self.renderer_name = name
            self.say(f"выбрано: {name}")

    def _on_launch(self, _btn, cmd, label):
        err = run_detached([cmd], self.renderer)
        if err:
            self.say(f"не запустилось: {label} — {err}")
        else:
            env_str = " ".join(f"{k}={v}" for k, v in sorted(self.renderer.items()))
            self.say(f"{label}: {env_str}")

    # ---- страница оболочки ------------------------------------------
    # ---- страница кадров --------------------------------------------
    #
    # Наблюдение пользователя: крутилка при запуске приложения плавная
    # всегда, а прокрутка списка нет. Разница между ними не в GPU и не в
    # масштабе, а в площади перерисовки. Здесь она и меряется.
    #
    # Три режима отличаются ровно одним:
    #
    #   весь экран   большая площадь + много работы cairo
    #   квадрат      маленькая площадь + столько же работы на точку
    #   заливка      большая площадь + почти нулевая работа cairo
    #
    # Третий и есть развилка. Если заливка идёт быстро, а «весь экран»
    # медленно — платим за отрисовку процессором. Если оба медленные —
    # платим за доставку кадра, и тогда виноват путь вывода, а не cairo.
    def _frames_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_start(12)
        box.set_margin_end(12)

        hint = Gtk.Label()
        hint.set_markup(
            "<b>Где теряются кадры.</b> Крутилка плавная, прокрутка нет —\n"
            "разница в площади перерисовки, а не в GPU.\n\n"
            "«Заливка» — та же площадь, что и «весь экран», но работы для\n"
            "процессора почти нет. Если она быстрая, а «весь экран» нет —\n"
            "виновата отрисовка процессором. Если обе медленные — виноват\n"
            "путь вывода кадра."
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        box.pack_start(big(hint, 1.0), False, False, 4)

        if not HAVE_CAIRO:
            miss = Gtk.Label()
            miss.set_markup(
                "\n<b>Измерять нечем.</b> Нет пакета <tt>python3-gi-cairo</tt>,\n"
                "без него обработчик отрисовки не получает контекст cairo.\n"
                "Поставь его и открой страницу заново."
            )
            miss.set_line_wrap(True)
            box.pack_start(big(miss, 1.1), False, False, 8)
            return box

        self.fps_label = Gtk.Label(label="кадров/с: —")
        self.fps_label.set_xalign(0)
        self.fps_label.set_line_wrap(True)
        box.pack_start(big(self.fps_label, 1.8), False, False, 4)

        row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        first = None
        for label, mode in FRAME_MODES:
            btn = Gtk.RadioButton.new_with_label_from_widget(first, label)
            if first is None:
                first = btn
            btn.connect("toggled", self._on_frame_mode, mode)
            big(btn, 1.1)
            row.pack_start(btn, False, False, 0)
        box.pack_start(row, False, False, 0)

        self.frame_mode = FRAME_MODES[0][1]
        self._fps_n = 0
        self._fps_t0 = 0
        self._phase = 0.0

        mb = Gtk.Button(label="Замер копии кадра в памяти")
        mb.set_size_request(-1, 80)
        big(mb.get_child(), 1.15)
        mb.connect("clicked", self._measure_copy)
        box.pack_start(mb, False, False, 4)

        self.canvas = Gtk.DrawingArea()
        self.canvas.connect("draw", self._draw_frame)
        box.pack_start(self.canvas, True, True, 0)
        self.canvas.add_tick_callback(self._tick)
        return box

    def _measure_copy(self, _btn):
        """Сколько стоит один полный проход по кадру в обычной памяти.

        Нужно для арифметики: наблюдаемые 48 мс на полноэкранный кадр надо
        с чем-то соизмерить. Если один проход стоит X, то 48 мс это 48/X
        проходов — и тогда видно, ищем мы один просчёт или сумму нескольких
        неизбежных копий.

        memmove из libc, то есть ровно тот memcpy, которым копируют все
        остальные. Barrier не нужен: ctypes всё равно не оптимизируется.
        """
        import ctypes
        import time
        n = 1440 * 2960 * 4
        a = ctypes.create_string_buffer(n)
        b = ctypes.create_string_buffer(n)
        ctypes.memmove(b, a, n)                     # прогрев
        t0 = time.monotonic()
        reps = 10
        for _ in range(reps):
            ctypes.memmove(b, a, n)
        dt = (time.monotonic() - t0) / reps
        self.say("кадр %.1f МБ: один проход по памяти %.1f мс (%.0f МБ/с)"
                 % (n / 1048576.0, dt * 1e3, n / 1048576.0 / dt))

    def _on_frame_mode(self, btn, mode):
        if btn.get_active():
            self.frame_mode = mode
            self._fps_n = 0
            self._fps_t0 = 0

    def _tick(self, widget, clock):
        now = clock.get_frame_time()          # микросекунды
        if self._fps_t0 == 0:
            self._fps_t0 = now
        self._fps_n += 1
        dt = now - self._fps_t0
        if dt >= 1000000:
            self.fps_label.set_text(
                "%.1f кадр/с\n%.1f мс на кадр"
                % (self._fps_n * 1e6 / dt, dt / 1000.0 / self._fps_n))
            self._fps_n = 0
            self._fps_t0 = now

        self._phase += 0.05
        if self.frame_mode == "small":
            # Ровно как крутилка: трогаем крошечный кусок окна.
            widget.queue_draw_area(20, 20, 120, 120)
        else:
            widget.queue_draw()
        return GLib.SOURCE_CONTINUE

    def _draw_frame(self, widget, cr):
        import math
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()

        if self.frame_mode == "fill":
            # Та же площадь, но для процессора работы почти нет.
            cr.set_source_rgb(0.1, 0.2 + 0.2 * math.sin(self._phase), 0.35)
            cr.paint()
            return False

        cr.set_source_rgb(0.08, 0.09, 0.12)
        cr.paint()

        if self.frame_mode == "small":
            cx, cy, r = 80, 80, 50
        else:
            cx, cy, r = w / 2, h / 2, min(w, h) / 2.2

        # Нагрузка намеренно похожа на настоящий интерфейс: полупрозрачные
        # заливки со сглаживанием, а не один сплошной цвет.
        for i in range(24):
            a = self._phase + i * math.pi / 12
            cr.set_source_rgba(0.4 + 0.5 * math.sin(a), 0.5, 0.9, 0.35)
            cr.arc(cx + math.cos(a) * r * 0.5,
                   cy + math.sin(a) * r * 0.5, r * 0.35, 0, 2 * math.pi)
            cr.fill()
        return False

    # ---- страница журнала -------------------------------------------
    #
    # Вывод запущенных отсюда приложений идёт в ~/lab-logs. Без этой
    # страницы прочитать его можно было только из TWRP, то есть ценой
    # перезагрузки ради одной строчки.
    def _log_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_start(12)
        box.set_margin_end(12)

        btn = Gtk.Button(label="Обновить")
        btn.set_size_request(-1, 80)
        big(btn.get_child(), 1.25)
        btn.connect("clicked", self._reload_logs)
        box.pack_start(btn, False, False, 0)

        self.logview = Gtk.TextView()
        self.logview.set_editable(False)
        self.logview.set_monospace(True)
        self.logview.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        scroll = Gtk.ScrolledWindow()
        scroll.add(self.logview)
        box.pack_start(scroll, True, True, 0)
        return box

    def _reload_logs(self, _btn=None):
        try:
            names = sorted(os.listdir(LOGDIR))
        except OSError:
            self.logview.get_buffer().set_text(
                "Каталог %s ещё не создан — запусти что-нибудь со страницы "
                "приложений." % LOGDIR)
            return
        chunks = []
        for name in names:
            path = os.path.join(LOGDIR, name)
            try:
                with open(path, errors="replace") as fh:
                    tail = fh.read()[-4000:]
            except OSError as exc:
                tail = "(не читается: %s)" % exc
            chunks.append("===== %s =====\n%s" % (name, tail.strip() or "(пусто)"))
        self.logview.get_buffer().set_text(
            "\n\n".join(chunks) or "Пока пусто.")

    # ---- страница композитора ---------------------------------------
    def _comp_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_start(12)
        box.set_margin_end(12)

        hint = Gtk.Label()
        hint.set_markup(
            "<b>Как композитор забирает кадр.</b> Замер показал, что теряется\n"
            "именно здесь: клиент с буфером GPU идёт 48-81 кадр/с на всю\n"
            "площадь, а клиент с буфером в памяти — 20, хотя рисовать там\n"
            "почти нечего.\n\n"
            "Причина в раскладке: буфер GTK3 лежит построчно, текстуры Mali\n"
            "уложены тайлами, и загрузка кадра — перекладывание каждого\n"
            "пикселя процессором.\n\n"
            "Оболочка перезапустится, пульт закроется — открой заново."
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        box.pack_start(big(hint, 1.0), False, False, 4)

        for label, arg in COMPOSITORS:
            btn = Gtk.Button(label=label)
            btn.set_size_request(-1, 88)
            big(btn.get_child(), 1.15)
            btn.connect("clicked", self._on_comp, arg, label)
            box.pack_start(btn, False, False, 0)
        return box

    def _on_comp(self, _btn, arg, label):
        self.say("ставлю: %s…" % label)
        out = self._helper([arg])
        self.say(out or label)

    # ---- страница масштаба ------------------------------------------
    def _scale_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_start(12)
        box.set_margin_end(12)

        hint = Gtk.Label()
        hint.set_markup(
            "<b>Масштаб экрана.</b> Целое число здесь важно не только для\n"
            "чёткости. GTK3, на котором написана вся оболочка, дробный\n"
            "масштаб не умеет: phoc выдаёт таким клиентам ближайшее целое\n"
            "сверху и потом ужимает картинку. При 3.075 оболочка рисуется\n"
            "как при 4 — это 1.7 раза лишних пикселей плюс пересэмплирование\n"
            "каждого кадра.\n\n"
            "Выбор в настройках между перезагрузками не держится: у simpledrm\n"
            "нет ни EDID, ни серийного номера, опознать монитор нечем. Здесь\n"
            "он пишется в phoc.ini, поэтому переживает перезагрузку.\n\n"
            "Оболочка перезапустится, пульт закроется — открой заново."
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        box.pack_start(big(hint, 1.0), False, False, 4)

        for label, arg in SCALES:
            btn = Gtk.Button(label=label)
            btn.set_size_request(-1, 88)
            big(btn.get_child(), 1.25)
            btn.connect("clicked", self._on_scale, arg, label)
            box.pack_start(btn, False, False, 0)
        return box

    def _on_scale(self, _btn, arg, label):
        self.say(f"ставлю {label}…")
        out = self._helper([arg])
        self.say(out or f"масштаб: {label}")

    def _shell_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_margin_start(12)
        box.set_margin_end(12)

        hint = Gtk.Label()
        hint.set_markup(
            "<b>Смена оболочки.</b> Обе остаются установленными, меняется\n"
            "только то, какая включена. Требуется перезагрузка.\n\n"
            "GNOME на этом устройстве работает лишь с программным рендером:\n"
            "mutter берёт основным GPU simpledrm, panfrost отвергает и падает.\n"
            "Поэтому вместе с оболочкой переключается и blacklist panfrost."
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        box.pack_start(big(hint, 1.0), False, False, 4)

        for label, name in SHELLS:
            btn = Gtk.Button(label=label)
            btn.set_size_request(-1, 96)
            big(btn.get_child(), 1.25)
            btn.connect("clicked", self._on_shell, name)
            box.pack_start(btn, False, False, 0)

        box.pack_start(Gtk.Separator(), False, False, 8)
        rb = Gtk.Button(label="Перезагрузить телефон")
        rb.set_size_request(-1, 96)
        big(rb.get_child(), 1.25)
        rb.connect("clicked", lambda *_: self._helper(["reboot"]))
        box.pack_start(rb, False, False, 0)
        return box

    def _on_shell(self, _btn, name):
        out = self._helper([name])
        self.say(out or f"оболочка переключена на {name}, нужна перезагрузка")

    def _helper(self, args):
        try:
            res = subprocess.run(
                ["sudo", "-n", "/usr/local/bin/dreamlte-switch-shell"] + args,
                capture_output=True, text=True, timeout=30)
            if res.returncode != 0:
                return f"помощник вернул {res.returncode}: {res.stderr.strip()[:120]}"
            return res.stdout.strip()[:160]
        except Exception as exc:  # noqa: BLE001
            return f"не вышло: {exc}"

    # ---- страница состояния -----------------------------------------
    def _info_page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_start(12)
        box.set_margin_end(12)

        self.info = Gtk.Label(label="нажми «Обновить»")
        self.info.set_xalign(0)
        self.info.set_yalign(0)
        self.info.set_line_wrap(True)
        self.info.set_selectable(True)
        big(self.info, 1.0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.info)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        for label, fn in (("Обновить", self._refresh),
                          ("Снимок экрана", self._screenshot)):
            btn = Gtk.Button(label=label)
            btn.set_size_request(-1, 88)
            big(btn.get_child(), 1.25)
            btn.connect("clicked", fn)
            row.pack_start(btn, False, False, 0)

        box.pack_start(row, False, False, 0)
        box.pack_start(scroll, True, True, 0)
        GLib.idle_add(self._refresh, None)
        return box

    def _refresh(self, _btn):
        lines = []

        clk = "?"
        try:
            with open("/sys/kernel/debug/clk/clk_summary") as fh:
                for ln in fh:
                    if "gout_g3d_agpu" in ln:
                        parts = ln.split()
                        if len(parts) > 4:
                            clk = f"{int(parts[4]) / 1e6:.0f} МГц"
                        break
        except OSError:
            clk = "нет доступа (нужен root)"
        lines.append(f"Частота GPU: {clk}")

        lines.append("Устройства DRM:")
        for card in sorted(os.listdir("/sys/class/drm")):
            drv = read_first(f"/sys/class/drm/{card}/device/uevent", "")
            m = re.search(r"DRIVER=(\S+)", drv)
            if m:
                lines.append(f"  {card}: {m.group(1)}")

        try:
            dmesg = subprocess.run(["dmesg"], capture_output=True, text=True,
                                   timeout=10).stdout
            n = dmesg.count("sched timeout")
            lines.append(f"Сбросов GPU по таймауту: {n}")
        except Exception:  # noqa: BLE001
            lines.append("Сбросов GPU: нет доступа к dmesg")

        # Без этого невозможно отличить "версия не подтвердилась" от
        # "настройка не доехала до композитора". На переключении текстур
        # в линейные я упёрся ровно в это.
        lines.append("Композитор сейчас работает с:")
        for k, v in sorted(phoc_env().items()):
            lines.append(f"  {k}={v}")
        lines.append(f"Масштаб в phoc.ini: {phoc_scale()}")

        lines.append(f"Выбрано для запуска: {self.renderer_name}")
        for k, v in sorted(self.renderer.items()):
            lines.append(f"  {k}={v}")
        lines.append(f"Снимки экрана: {SHOTS}")
        self.info.set_text("\n".join(lines))
        return False

    def _screenshot(self, _btn):
        os.makedirs(SHOTS, exist_ok=True)
        name = os.path.join(SHOTS, "lab-" + str(int(GLib.get_real_time() / 1e6)) + ".png")
        err = run_detached(["grim", name])
        self.say(err or f"снимок: {os.path.basename(name)}")


def main():
    """Запуск с записью падения в файл.

    Без этого пульт, упавший при старте, выглядит как «не запускается», и
    причину видно только из журнала — а до журнала на этом устройстве
    добираться через TWRP. Пусть лучше сам расскажет.
    """
    log = os.path.expanduser("~/dreamlte-lab-error.log")
    try:
        win = Lab()
        win.show_all()
        Gtk.main()
    except Exception:  # noqa: BLE001
        import traceback
        with open(log, "w") as fh:
            traceback.print_exc(file=fh)
        traceback.print_exc()
        raise


if __name__ == "__main__":
    main()
