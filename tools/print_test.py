#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later — part of P1Label (GPL-3.0-or-later).
"""Send a test label to the P1 over USB using the reverse-engineered LPAPI protocol.

Page flow:
  [0x1F 32 keyHi keyLo crc]              PAGE_START (pageKey, 2B big-endian)
  [0x1F 39 EBV(byteWidth) crc]           PAGE_WIDTH (bytes per raster line)
  rows: bitmap print [0x1F 43 EBV(skip) EBV(len) data crc]
        blank line      [0x1B 0x4B n]  (ESC J)
        repeat          [0x1F 46 EBV(count-1) crc]
  0x0C                                   end-of-page
"""
import sys, time
import usb.core, usb.util
from PIL import Image, ImageDraw, ImageFont

VID, PID = 0x3533, 0x5A11
CMD_PAGE_START, CMD_PAGE_WIDTH, CMD_BITMAP_PRINT, CMD_BITMAP_REPEAT = 32, 39, 43, 46
CMD_IS_PRINTABLE, CMD_BUFFER_SIZE = 112, 119

def ebv(n):
    return [(n >> 8) | 192, n & 0xFF] if n >= 192 else [n]

CRC_FIXED = 0x88  # host->device packages always carry the fixed CRC marker

def frame(cmd, data=b""):
    """Framed command package with fixed CRC byte (as the official SDK sends)."""
    return bytes([0x1F, cmd] + ebv(len(data)) + list(data) + [CRC_FIXED])

def bitmap_row(skip, data):
    """Bitmap print row: NO CRC byte, header + raw raster bytes."""
    return bytes([0x1F, CMD_BITMAP_PRINT] + ebv(skip) + ebv(len(data)) + list(data))

def bitmap_repeat(count):
    """Repeat last bitmap row `count` times: header + EBV(count-1), NO CRC."""
    return bytes([0x1F, CMD_BITMAP_REPEAT] + ebv(count - 1))

def parse_pkgs(buf):
    """Yield (cmd, data) packages from a byte stream, return remaining buffer."""
    out = []
    i = 0
    while True:
        while i < len(buf) and buf[i] != 0x1F:
            i += 1
        if i >= len(buf):
            return out, bytearray()
        rest = buf[i:]
        if len(rest) < 4:
            return out, rest
        if rest[2] >= 192:
            if len(rest) < 4: return out, rest
            ln = ((rest[2] & ~192) << 8) | rest[3]
            if len(rest) < ln + 5: return out, rest
            out.append((rest[1], bytes(rest[4:4+ln])))
            i += ln + 5
        else:
            ln = rest[2]
            if len(rest) < ln + 4: return out, rest
            out.append((rest[1], bytes(rest[3:3+ln])))
            i += ln + 4

class Printer:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VID, idProduct=PID)
        if self.dev is None:
            raise SystemExit("printer not found")
        if self.dev.is_kernel_driver_active(0):
            self.dev.detach_kernel_driver(0)
        self.dev.set_configuration()
        intf = self.dev.get_active_configuration()[(0, 0)]
        self.ep_out = usb.util.find_descriptor(intf, custom_match=lambda e: e.bEndpointAddress == 0x01)
        self.ep_in = usb.util.find_descriptor(intf, custom_match=lambda e: e.bEndpointAddress == 0x81)
        self.rx = bytearray()

    def pump(self, timeout=200):
        try:
            self.rx.extend(self.ep_in.read(64, timeout=timeout))
        except usb.core.USBError:
            pass

    def send(self, data):
        for i in range(0, len(data), 64):
            self.ep_out.write(data[i:i+64], timeout=2000)

    def drain(self, quiet_ms=300):
        end = time.time() + quiet_ms / 1000
        while time.time() < end:
            self.pump(100)
        pkgs, self.rx = parse_pkgs(self.rx)
        return pkgs

    def query(self, cmd, timeout=2.0):
        self.send(frame(cmd))
        end = time.time() + timeout
        while time.time() < end:
            pkgs, self.rx = parse_pkgs(self.rx)
            for c, d in pkgs:
                if c == cmd:
                    return d
            self.pump(100)
        return None

    def buffer_size(self):
        d = self.query(CMD_BUFFER_SIZE)
        if not d: return -1
        return d[1] | (d[0] << 8) if len(d) >= 2 else d[0]

    def printable(self):
        d = self.query(CMD_IS_PRINTABLE)
        return d[0] if d else -1

def make_test_image(width_dots=384):
    h = 200
    img = Image.new("L", (width_dots, h), 255)
    dr = ImageDraw.Draw(img)
    dr.rectangle([0, 0, width_dots - 1, h - 1], outline=0, width=3)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 32)
        small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 24)
    except OSError:
        font = small = ImageFont.load_default()
    dr.text((12, 12), "HELLO P1", font=font, fill=0)
    dr.text((12, 56), "Mac USB Test 203dpi", font=small, fill=0)
    dr.text((12, 92), "2026-11-05", font=small, fill=0)
    # test pattern strip
    for x in range(12, width_dots - 12, 8):
        dr.rectangle([x, 140, x + 3, 170], fill=0)
    return img.point(lambda p: 0 if p < 128 else 255).convert("1")

def encode_rows(img):
    """Return list of buffers for the page body."""
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
        if nz == 0:  # consecutive blank rows -> ESC J
            n = 0
            while i < len(rows) and max(rows[i]) == 0:
                n += 1; i += 1
            while n >= 255:
                bufs.append(bytes([27, 74, 255])); n -= 255
            if n > 0:
                bufs.append(bytes([27, 74, n]))
            continue
        # repeat identical rows
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
    print("buffer size:", p.buffer_size())
    print("printable:", p.printable())
    img = make_test_image()
    bw = (img.size[0] + 7) // 8
    page_key = 123
    body = bytearray()
    body += frame(CMD_PAGE_START, page_key.to_bytes(2, "big"))
    body += frame(CMD_PAGE_WIDTH, ebv(bw))
    for b in encode_rows(img):
        body += b
    body += b"\x0c"
    print(f"sending {len(body)} bytes...")
    # send in chunks with buffer polling
    pos = 0
    while pos < len(body):
        bs = p.buffer_size()
        if bs < 0:
            print("!! buffer size query failed, assuming ok")
            bs = 8192
        if bs < 512:
            time.sleep(0.3)
            continue
        chunk = body[pos:pos + 1024]
        p.send(chunk)
        pos += len(chunk)
    print("sent. reading responses...")
    for cmd, d in p.drain(1500):
        print(f"  resp cmd={cmd} data={d.hex()}")
    time.sleep(2)
    for cmd, d in p.drain(2000):
        print(f"  resp cmd={cmd} data={d.hex()}")
    print("done")

if __name__ == "__main__":
    main()
