#!/usr/bin/env python3
"""Интерактивный установщик чистого Debian на Samsung Galaxy S8.

ADB работает нативно на Linux и Windows. Сборка arm64 rootfs на Windows
запускается через WSL, потому что debootstrap/chroot нужны для подготовки
Debian. Форматирование и прошивка требуют отдельных подтверждений точными
фразами.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path


class UserAbort(Exception):
    pass


def say(message: str = "") -> None:
    print(message, flush=True)


def run(command: list[str], *, check: bool = True, capture: bool = False,
        cwd: Path | None = None, env: dict[str, str] | None = None):
    shown = " ".join(str(item) for item in command)
    say(f"$ {shown}")
    try:
        return subprocess.run(
            [str(item) for item in command],
            cwd=str(cwd) if cwd else None,
            env=env,
            check=check,
            text=capture,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except subprocess.CalledProcessError as error:
        raise UserAbort(f"Команда завершилась с кодом {error.returncode}.") from error


def ask(prompt: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{prompt}{suffix}: ").strip()
    return value or default


def yes_no(prompt: str, default: bool = False) -> bool:
    suffix = "Y/n" if default else "y/N"
    value = input(f"{prompt} [{suffix}]: ").strip().lower()
    if not value:
        return default
    return value in {"y", "yes", "д", "да"}


def choose(title: str, items: list[tuple[str, str]], default: int = 0) -> str:
    say(f"\n{title}")
    for number, (_value, description) in enumerate(items, 1):
        marker = " (рекомендуется)" if number - 1 == default else ""
        say(f"  {number}. {description}{marker}")
    while True:
        value = input(f"Выбор [{default + 1}]: ").strip()
        if not value:
            return items[default][0]
        if value.isdigit() and 1 <= int(value) <= len(items):
            return items[int(value) - 1][0]
        say("Введите номер пункта.")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def find_adb(root: Path) -> Path | None:
    suffix = ".exe" if platform.system() == "Windows" else ""
    candidates: list[Path] = []
    configured = os.environ.get("LINUXS8_ADB")
    if configured:
        candidates.append(Path(configured))
    candidates.extend([
        root / "build" / "tools" / "platform-tools" / f"adb{suffix}",
        root / "build" / "installer-cache" / "platform-tools" / f"adb{suffix}",
    ])
    found = shutil.which("adb")
    if found:
        candidates.append(Path(found))
    return next((path for path in candidates if path.is_file()), None)


def download_adb(root: Path) -> Path:
    system = platform.system()
    if system == "Windows":
        url = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
        executable = "adb.exe"
    elif system == "Linux":
        url = "https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
        executable = "adb"
    else:
        raise UserAbort("Поддерживаются только Linux и Windows.")
    cache = root / "build" / "installer-cache"
    unpacked = cache / "platform-tools"
    adb = unpacked / executable
    if not adb.is_file():
        cache.mkdir(parents=True, exist_ok=True)
        archive = cache / "platform-tools.zip"
        say(f"adb не найден, скачиваю официальные platform-tools: {url}")
        urllib.request.urlretrieve(url, archive)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(cache)
        if not adb.is_file():
            raise UserAbort(f"В архиве нет {adb}.")
        if system != "Windows":
            adb.chmod(adb.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return adb


def wsl_path(path: Path) -> str:
    result = subprocess.run(
        ["wsl.exe", "wslpath", "-a", str(path)],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise UserAbort(f"WSL не смог преобразовать путь {path}: {result.stderr.strip()}")
    return result.stdout.strip()


def ask_password() -> str:
    password = getpass.getpass("Пароль выбранного аккаунта: ")
    confirmation = getpass.getpass("Повторите пароль: ")
    if not password or password != confirmation:
        raise UserAbort("Пароли пустые или не совпали.")
    return password


def build_rootfs(root: Path, suite: str, desktop: str, user: str,
                 hostname: str, label: str, scale: str, password: str) -> Path:
    output = root / "build" / "installer" / f"rootfs-{suite}-{desktop}-scale{scale}"
    archive = Path(str(output) + ".tar.gz")
    if archive.is_file():
        if yes_no(f"Найден готовый локальный rootfs {archive}. Использовать его", True):
            return archive
        raise UserAbort("Сборка отменена: выберите повторное использование или удалите артефакт вручную.")

    builder = root / "scripts" / "build-clean-rootfs.sh"
    if not builder.is_file():
        raise UserAbort(f"Не найден сборщик: {builder}")
    password_dir = root / "build" / "installer"
    password_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", prefix=".password-", dir=password_dir,
        delete=False,
    ) as secret:
        secret.write(password + "\n")
        secret_path = Path(secret.name)
    secret_path.chmod(0o600)

    args = [
        "bash", "scripts/build-clean-rootfs.sh",
        "--suite", suite, "--desktop", desktop, "--user", user,
        "--hostname", hostname, "--root-label", label, "--scale", scale,
        "--output", str(output), "--password-file",
        str(secret_path),
    ]
    kernel_tree = root / "build" / "src" / "linux"
    if kernel_tree.is_dir():
        args.extend(["--kernel-tree", str(kernel_tree)])
    try:
        if platform.system() == "Windows":
            wsl = shutil.which("wsl.exe")
            if not wsl:
                raise UserAbort(
                    "На Windows сборка arm64 Debian требует WSL2. "
                    "Установите WSL2 с Debian/Ubuntu и повторите."
                )
            command = [wsl, "--cd", wsl_path(root), "--", "sudo", "-E", *args]
            command[command.index(str(output))] = wsl_path(output)
            command[command.index(str(secret_path))] = wsl_path(secret_path)
            if str(kernel_tree) in command:
                command[command.index(str(kernel_tree))] = wsl_path(kernel_tree)
            say("Rootfs собирается в WSL; ADB и прошивка останутся нативными Windows.")
        else:
            command = args
            if os.geteuid() != 0:
                if not shutil.which("sudo"):
                    raise UserAbort("Нужен root или sudo для debootstrap.")
                command = ["sudo", "-E", *command]
        run(command, cwd=root)
    finally:
        try:
            secret_path.unlink()
        except FileNotFoundError:
            pass
    if not archive.is_file():
        raise UserAbort(f"Сборщик завершился без архива: {archive}")
    return archive


class Adb:
    def __init__(self, path: Path):
        self.path = path

    def call(self, args: list[str], *, check: bool = True, capture: bool = False):
        return run([str(self.path), *args], check=check, capture=capture)

    def shell(self, command: str, *, check: bool = True, capture: bool = False):
        return self.call(["shell", command], check=check, capture=capture)

    def state(self) -> str:
        result = self.call(["get-state"], check=False, capture=True)
        return result.stdout.strip() if result.stdout else ""

    def wait_for_twrp(self) -> None:
        say("\nТелефон должен быть в TWRP. Если он ещё загружается, оставьте кабель подключённым.")
        last = None
        while True:
            state = self.state()
            if state == "recovery":
                say("TWRP обнаружен.")
                return
            if state != last:
                if state == "device":
                    say("Телефон виден, но это загруженная система; жду TWRP.")
                else:
                    say("Телефон пока не виден по ADB; жду TWRP.")
                last = state
            time.sleep(3)

    def summary(self) -> str:
        result = self.shell(
            "printf 'device='; getprop ro.product.device; "
            "printf 'model='; getprop ro.product.model",
            check=False, capture=True,
        )
        return (result.stdout or "").strip()

    def push(self, source: Path, destination: str) -> None:
        self.call(["push", str(source), destination])

    def pull_partition(self, partition: str, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        say(f"Сохраняю локальную копию {partition}: {destination}")
        with destination.open("wb") as output:
            process = subprocess.Popen(
                [str(self.path), "exec-out", "dd", f"if=/dev/block/{partition}", "bs=4M"],
                stdout=output, stderr=subprocess.PIPE,
            )
            _, error = process.communicate()
        if process.returncode:
            raise UserAbort(f"Не удалось сохранить {partition}: {error.decode(errors='replace')}")
        say(f"sha256 {destination.name}: {sha256_file(destination)}")

    def read_prefix(self, partition: str, byte_count: int) -> bytes:
        block_size = 4096
        count = (byte_count + block_size - 1) // block_size
        process = subprocess.Popen(
            [str(self.path), "exec-out", "dd", f"if=/dev/block/{partition}",
             f"bs={block_size}", f"count={count}"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        data, error = process.communicate()
        if process.returncode:
            raise UserAbort(f"Не удалось прочитать {partition}: {error.decode(errors='replace')}")
        return data[:byte_count]


def partition_bytes(adb: Adb, partition: str) -> int | None:
    result = adb.shell(f"cat /sys/class/block/{partition}/size", check=False, capture=True)
    try:
        return int((result.stdout or "").strip()) * 512
    except ValueError:
        return None


def ask_backup(adb: Adb) -> None:
    if not yes_no("Сделать локальный TWRP-бэкап sda7 и текущего sda29 перед очисткой", True):
        say("Бэкап пропущен по выбору пользователя.")
        return
    default_dir = Path.home() / f"LinuxS8-backup-{time.strftime('%Y%m%d-%H%M%S')}"
    backup_dir = Path(ask("Каталог бэкапа", str(default_dir))).expanduser().resolve()
    if backup_dir.exists() and any(backup_dir.iterdir()):
        raise UserAbort(f"Каталог бэкапа не пуст: {backup_dir}")
    backup_dir.mkdir(parents=True, exist_ok=True)
    size = partition_bytes(adb, "sda29")
    if size:
        say(f"Размер sda29: {size / (1024 ** 3):.1f} GiB; потребуется столько свободного места.")
    adb.pull_partition("sda7", backup_dir / "boot-before-install.img")
    adb.pull_partition("sda29", backup_dir / "userdata-before-install.img")
    say(f"Бэкап сохранён только локально: {backup_dir}")


def exact_confirmation(prompt: str, phrase: str) -> None:
    value = input(f"{prompt}\nВведите {phrase!r} для продолжения: ").strip()
    if value != phrase:
        raise UserAbort("Подтверждение не совпало; операция отменена до изменения телефона.")


def format_and_extract(adb: Adb, label: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,16}", label):
        raise UserAbort("Недопустимая метка ext4.")
    shell_label = shlex.quote(label)
    command = "\n".join([
        "set -eu",
        "TARGET=/dev/block/sda29",
        "for mountpoint in $(grep '^/dev/block/sda29 ' /proc/mounts | cut -d' ' -f2); do",
        '    umount "$mountpoint" || true',
        "done",
        "if command -v mkfs.ext4 >/dev/null 2>&1; then",
        f"    mkfs.ext4 -F -L {shell_label} \"$TARGET\"",
        "elif command -v mke2fs >/dev/null 2>&1; then",
        f"    mke2fs -t ext4 -F -L {shell_label} \"$TARGET\"",
        "else",
        "    echo 'В TWRP нет mkfs.ext4 или mke2fs' >&2",
        "    exit 1",
        "fi",
        "mkdir -p /mnt/linuxroot",
        "mount -t ext4 \"$TARGET\" /mnt/linuxroot",
        "tar -xzf /tmp/linuxs8-rootfs.tar.gz -C /mnt/linuxroot",
        "test -x /mnt/linuxroot/sbin/init",
        "sync",
        "rm -f /tmp/linuxs8-rootfs.tar.gz",
    ])
    adb.shell(command)
    say(f"Чистый rootfs распакован на sda29 с меткой {label}.")


def flash_boot(adb: Adb, boot_image: Path) -> None:
    adb.shell("dd if=/tmp/linuxs8-boot.img of=/dev/block/sda7 bs=4096; sync; rm -f /tmp/linuxs8-boot.img")
    source_hash = sha256_file(boot_image)
    readback_hash = hashlib.sha256(adb.read_prefix("sda7", boot_image.stat().st_size)).hexdigest()
    say(f"boot sha256 source:   {source_hash}")
    say(f"boot sha256 readback: {readback_hash}")
    if readback_hash != source_hash:
        raise UserAbort("Проверка boot readback не совпала; перезагрузка отменена.")
    say("boot раздел проверен побайтно по длине образа.")


def find_boot_image(root: Path) -> Path | None:
    for name in (
        "boot_safe-battery-fixed.img",
        "boot_safe-battery.img",
        "boot_kms-native-safe.img",
    ):
        candidate = root / "build" / "device-backups" / name
        if candidate.is_file():
            return candidate
    return None


def download_boot_image(root: Path, url: str) -> Path:
    cache = root / "build" / "installer-cache"
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / "boot-from-release.img"
    say(f"Скачиваю boot-образ: {url}")
    urllib.request.urlretrieve(url, destination)
    if destination.stat().st_size == 0:
        raise UserAbort("Скачанный boot-образ пустой.")
    say(f"boot-образ сохранён: {destination}; sha256={sha256_file(destination)}")
    return destination


def get_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["trixie", "bookworm", "stable"])
    parser.add_argument("--desktop", choices=["phosh", "gnome"])
    parser.add_argument("--user")
    parser.add_argument("--hostname")
    parser.add_argument("--root-label")
    parser.add_argument("--scale", choices=["1", "2", "3", "4"])
    parser.add_argument("--rootfs-archive", type=Path)
    parser.add_argument("--boot-image", type=Path)
    parser.add_argument("--boot-url")
    parser.add_argument("--rootfs-only", action="store_true",
                        help="разрешить установку без boot-образа; обычно не нужно")
    parser.add_argument("--skip-backup", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = get_args()
    root = repo_root()
    say("LinuxS8 — установщик чистого Debian для Samsung Galaxy S8 (dreamlte)")
    say("Персональный текущий rootfs не используется: новый образ строится с нуля из Debian.")

    suite = args.suite or choose(
        "Версия Debian",
        [("trixie", "Debian 13 trixie"), ("bookworm", "Debian 12 bookworm"),
         ("stable", "stable alias")],
    )
    desktop = args.desktop or choose(
        "Графическая оболочка",
        [("phosh", "Phosh — профиль телефона"), ("gnome", "GNOME — экспериментальный")],
    )
    scale = args.scale or choose(
        "Масштаб интерфейса",
        [("3", "300% — рекомендуемый режим"), ("2", "200%"),
         ("4", "400%"), ("1", "100%")],
    )
    user = args.user or ask("Имя аккаунта", "phone")
    normalized_user = user.lower()
    if normalized_user != user:
        say(f"Имя Linux-аккаунта приведено к строчным буквам: {user} -> {normalized_user}")
        user = normalized_user
    hostname = args.hostname or ask("Имя телефона", "dreamlte")
    label = args.root_label or ask("Метка rootfs", "linuxroot")
    password = ask_password()

    archive = args.rootfs_archive.expanduser().resolve() if args.rootfs_archive else \
        build_rootfs(root, suite, desktop, user, hostname, label, scale, password)
    if not archive.is_file():
        raise UserAbort(f"Архив rootfs не найден: {archive}")
    say(f"Rootfs: {archive} ({archive.stat().st_size / (1024 ** 2):.1f} MiB)")

    boot_image = args.boot_image.expanduser().resolve() if args.boot_image else find_boot_image(root)
    boot_url = args.boot_url or os.environ.get("LINUXS8_BOOT_URL")
    if not boot_image and boot_url:
        boot_image = download_boot_image(root, boot_url)
    if not boot_image and not args.rootfs_only and sys.stdin.isatty():
        boot_url = ask("URL boot-образа проекта (пусто — отмена)")
        if boot_url:
            boot_image = download_boot_image(root, boot_url)
    if boot_image and boot_image.is_file():
        say(f"Boot-образ: {boot_image}")
    elif args.rootfs_only:
        say("Boot-образ не выбран; будет установлен только rootfs.")
    else:
        raise UserAbort(
            "Не найден boot-образ. Укажите --boot-image path/to/boot.img "
            "или соберите его; без него новый rootfs не загрузится."
        )

    adb_path = find_adb(root) or download_adb(root)
    adb = Adb(adb_path)
    adb.call(["start-server"], check=False)
    adb.wait_for_twrp()
    say(adb.summary())
    say("Ожидается Samsung dreamlte / SM-G950F; если TWRP показывает другую модель, отмените Ctrl+C.")

    if not args.skip_backup:
        ask_backup(adb)
    exact_confirmation(
        "ВНИМАНИЕ: сейчас будет размонтирован и полностью отформатирован внутренний раздел sda29.\n"
        "Все текущие Windows/Linux данные на нём будут удалены.",
        "FORMAT sda29",
    )
    adb.push(archive, "/tmp/linuxs8-rootfs.tar.gz")
    format_and_extract(adb, label)

    if boot_image:
        exact_confirmation(
            "Rootfs уже записан. Теперь будет перепрошит загрузочный раздел sda7.",
            "FLASH sda7",
        )
        adb.push(boot_image, "/tmp/linuxs8-boot.img")
        flash_boot(adb, boot_image)

    adb.shell("sync")
    if yes_no("Перезагрузить телефон из TWRP сейчас", True):
        adb.call(["reboot"])
        say("Телефон перезагружается. Первый старт Debian может занять несколько минут.")
    else:
        say("Установка записана, перезагрузка оставлена пользователю.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, UserAbort) as error:
        say(f"Остановлено: {error}")
        raise SystemExit(2)
