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
# так что выбор на самом деле бинарный.
RENDERERS = [
    ("ngl — как сейчас (OpenGL)", ""),
    ("cairo — процессором", "cairo"),
]

SHELLS = [
    ("phosh — оболочка для телефона", "phosh"),
    ("GNOME — привычный рабочий стол", "gnome"),
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


def run_detached(cmd, env_extra=None):
    """Запуск без ожидания: пульт не должен блокироваться на приложении."""
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    try:
        subprocess.Popen(cmd, env=env, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return None
    except Exception as exc:  # noqa: BLE001
        return str(exc)


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
        self.renderer = ""

        stack = Gtk.Stack()
        stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
        switcher = Gtk.StackSwitcher(stack=stack)

        stack.add_titled(self._apps_page(), "apps", "Приложения")
        stack.add_titled(self._shell_page(), "shell", "Оболочка")
        stack.add_titled(self._info_page(), "info", "Состояние")

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
            "<b>Отрисовщик GTK4.</b> Приложения на GTK4 с ngl рисуются\n"
            "сломанными: пропадают скругления, текст и полупрозрачные слои.\n"
            "cairo считает содержимое процессором — медленнее, но верно."
        )
        hint.set_xalign(0)
        hint.set_line_wrap(True)
        box.pack_start(big(hint, 1.0), False, False, 4)

        first = None
        for label, value in RENDERERS:
            btn = Gtk.RadioButton.new_with_label_from_widget(first, label)
            if first is None:
                first = btn
            btn.connect("toggled", self._on_renderer, value)
            box.pack_start(big(btn, 1.2), False, False, 0)

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

    def _on_renderer(self, btn, value):
        if btn.get_active():
            self.renderer = value
            self.say(f"отрисовщик: {value or 'ngl (по умолчанию)'}")

    def _on_launch(self, _btn, cmd, label):
        env = {"GSK_RENDERER": self.renderer} if self.renderer else {}
        # Пустое значение хуже отсутствия: GTK ругается на неизвестное имя.
        if not self.renderer:
            env = {}
            os.environ.pop("GSK_RENDERER", None)
        err = run_detached([cmd], env)
        if err:
            self.say(f"не запустилось: {label} — {err}")
        else:
            self.say(f"запущено: {label}, отрисовщик "
                     f"{self.renderer or 'ngl'}")

    # ---- страница оболочки ------------------------------------------
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
            row.pack_start(btn, True, True, 0)

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

        lines.append(f"Текущий отрисовщик для запуска: {self.renderer or 'ngl'}")
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
