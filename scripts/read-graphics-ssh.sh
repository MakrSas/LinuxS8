#!/usr/bin/env bash
# Снимает состояние графического стека с загруженного телефона по SSH.
# Пароль SSH вводится самим ssh; в TWRP возвращаться не нужно.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-phone@10.99.0.2}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${2:-$ROOT/build/graphics-results/$STAMP}"
SSH_ARGS=()

# Можно передать уже открытое multiplex-соединение: это особенно удобно
# во время серии графических перезагрузок, когда пароль не нужно вводить
# для каждого снимка.
if [ -n "${SSH_CONTROL_PATH:-}" ]; then
	SSH_ARGS+=( -o "ControlPath=$SSH_CONTROL_PATH" -o ControlMaster=no )
fi

mkdir -p "$OUT"

ssh -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no \
    "${SSH_ARGS[@]}" \
    "$HOST" 'bash -s' <<'REMOTE' | tee "$OUT/graphics.log"
set +e
echo "=== host ==="
date -Is
uname -a
cat /proc/cmdline

echo "=== drm ==="
ls -l /dev/dri /dev/fb0 2>&1
for x in /sys/class/drm/*/device/driver; do
    printf '%s -> ' "$x"
    readlink "$x"
done 2>/dev/null
for x in /sys/class/drm/*/modes; do
    [ -f "$x" ] && { echo "--- $x"; cat "$x"; }
done

echo "=== framebuffer ==="
for x in /sys/class/graphics/fb0/{name,modes,virtual_size,stride,bits_per_pixel}; do
    [ -f "$x" ] && { echo "--- $x"; cat "$x"; }
done

echo "=== pstore ==="
found=0
for x in /sys/fs/pstore/*; do
    [ -f "$x" ] || continue
    found=1
    echo "--- $x"
    sed -n '1,240p' "$x"
done
[ "$found" -eq 1 ] || echo "(empty)"

echo "=== kernel graphics log ==="
dmesg | grep -Ei 'drm|decon|dsi|panel|framebuffer|simplefb|simpledrm|panfrost|gpu|mali' || true

echo "=== userspace compositor ==="
ps -eo pid,comm,args | grep -E 'phosh|phoc|cage|wayland|mutter' | grep -v grep || true

echo "=== current boot journal ==="
journalctl -b --no-pager -k -u phosh.service -u phoc.service 2>&1 | tail -240

echo "=== dreamlte logs ==="
find /var/log/dreamlte -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -10 | while read -r _ f; do
        echo "--- $f"
        tail -80 "$f"
    done
REMOTE

echo "Результат сохранён в $OUT/graphics.log"
