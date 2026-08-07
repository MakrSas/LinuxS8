#!/usr/bin/env python3
"""Swap the kernel inside a stock Android boot.img for our own payload.

The stock dreamlte boot.img is a plain AOSP v0 boot image: a 2048-byte header
page, then kernel / ramdisk / second / dt regions, each padded to a page
boundary. S-Boot (Samsung's non-replaceable bootloader) validates and loads
that layout, so rather than crafting an image from scratch we keep the
original header byte-for-byte -- load addresses, page size, cmdline, board
name, and the appended Samsung DTB region all stay exactly as the bootloader
expects -- and only replace the kernel region (with uniLoader, which itself
carries our mainline kernel + dtb + initramfs) and patch kernel_size to match.

Usage:
    repack-bootimg.py <stock-boot.img> <new-kernel> <output.img>
"""
import struct
import sys

# AOSP boot_img_hdr_v0 field offsets we care about.
OFF_KERNEL_SIZE = 8
OFF_RAMDISK_SIZE = 16
OFF_SECOND_SIZE = 24
OFF_PAGE_SIZE = 36
OFF_DT_SIZE = 40

# dreamlte's BOOT partition (/dev/block/sda7).
PARTITION_SIZE = 41943040


def main(stock_path, kernel_path, out_path):
    with open(stock_path, 'rb') as f:
        stock = f.read()

    if stock[:8] != b'ANDROID!':
        sys.exit(f'{stock_path}: not an Android boot image')

    header = bytearray(stock[:2048])
    page_size = struct.unpack_from('<I', header, OFF_PAGE_SIZE)[0]
    kernel_size = struct.unpack_from('<I', header, OFF_KERNEL_SIZE)[0]
    ramdisk_size = struct.unpack_from('<I', header, OFF_RAMDISK_SIZE)[0]
    second_size = struct.unpack_from('<I', header, OFF_SECOND_SIZE)[0]
    dt_size = struct.unpack_from('<I', header, OFF_DT_SIZE)[0]

    def pages(n):
        return (n + page_size - 1) // page_size

    def pad(data):
        return data + b'\x00' * (pages(len(data)) * page_size - len(data))

    # Regions follow the header page in fixed order, each page-aligned.
    off = page_size
    off += pages(kernel_size) * page_size
    ramdisk = stock[off:off + ramdisk_size]
    off += pages(ramdisk_size) * page_size
    second = stock[off:off + second_size]
    off += pages(second_size) * page_size
    dt = stock[off:off + dt_size]

    with open(kernel_path, 'rb') as f:
        kernel = f.read()
    struct.pack_into('<I', header, OFF_KERNEL_SIZE, len(kernel))

    out = bytes(header) + pad(kernel) + pad(ramdisk) + pad(second) + pad(dt)
    if len(out) > PARTITION_SIZE:
        sys.exit(f'image is {len(out)} bytes, exceeds {PARTITION_SIZE}-byte partition')

    with open(out_path, 'wb') as f:
        f.write(out)
    print(f'{out_path}: {len(out) / 1024 / 1024:.2f} MB '
          f'(kernel {len(kernel) / 1024 / 1024:.2f} MB, '
          f'{PARTITION_SIZE - len(out)} bytes spare)')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
