#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later — part of P1Label (GPL-3.0-or-later).
"""Fine offset calibration: vertical tick + number every 32 dots."""
import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from print_test import Printer, frame, ebv, bitmap_row, bitmap_repeat
from PIL import Image, ImageDraw, ImageFont

def make_page(width=384, height=120):
    img = Image.new("L", (width, height), 255)
    dr = ImageDraw.Draw(img)
    try:
        fs = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16)
    except OSError:
        fs = ImageFont.load_default()
    # vertical ticks every 16 dots, numbers every 32
    for x in range(0, width, 16):
        dr.line([(x, 10), (x, 20)], fill=0)
    for x in range(0, width, 32):
        # draw number rotated? keep simple horizontal, above the tick
        label = str(x)
        tw = dr.textlength(label, font=fs)
        dr.text((x - tw / 2, 24), label, font=fs, fill=0)
    # second band: horizontal lines starting at different x
    for i, x0 in enumerate(range(0, width, 48)):
        y = 60 + (i % 4) * 12
        dr.line([(x0, y), (width - 1 - x0, y)], fill=0)
    dr.rectangle([0, 0, width - 1, height - 1], outline=0, width=2)
    return img.point(lambda p: 0 if p < 128 else 255).convert("1")

def encode_rows(img):
    w, h = img.size
    byte_width = (w + 7) // 8
    px = img.load()
    rows = []
    for y in range(h):
        row = bytearray(byte_width)
        for x in range(w):
            if px[x, y] == 0:
                row[x // 8] |= 0x80 >> (x % 8)
        rows.append(bytes(row))
    bufs = []
    i = 0
    while i < len(rows):
        r = rows[i]
        nz = len(r)
        while nz > 0 and r[nz - 1] == 0:
            nz -= 1
        if nz == 0:
            n = 0
            while i < len(rows) and max(rows[i]) == 0:
                n += 1; i += 1
            while n >= 255:
                bufs.append(bytes([27, 74, 255])); n -= 255
            if n > 0:
                bufs.append(bytes([27, 74, n]))
            continue
        rep = 1
        while i + rep < len(rows) and rows[i + rep] == r:
            rep += 1
        bufs.append(bitmap_row(0, r[:nz]))
        if rep > 1:
            bufs.append(bitmap_repeat(rep - 1))
        i += rep
    return bufs

def main():
    p = Printer()
    print("buffer:", p.buffer_size(), "printable:", p.printable())
    img = make_page()
    bw = (img.size[0] + 7) // 8
    body = bytearray()
    body += frame(32, (124).to_bytes(2, "big"))
    body += frame(39, ebv(bw))
    body += b"".join(encode_rows(img))
    body += b"\x0c"
    print(f"send {len(body)} bytes")
    p.send(bytes(body))
    time.sleep(3)
    for cmd, d in p.drain(2000):
        print(f"resp cmd={cmd} data={d.hex()}")

if __name__ == "__main__":
    main()
