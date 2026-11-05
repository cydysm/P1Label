#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later — part of P1Label (GPL-3.0-or-later).
"""Probe DeTong P1 Label Printer (VID 0x3533 PID 0x5a11) over USB printer interface.

Protocol (reverse-engineered from lpapi-ble-uni SDK):
  Host->Device frame: [0x1F, cmd, EBV(len), data..., crc]
    - len < 192: single byte; else 2 bytes (len>>8|192, len&0xFF)
    - crc = ~(sum of bytes[1..end-of-data]) & 0xFF  (0x88 fixed also accepted)
  Device->Host: same framing starting with 0x1F.
"""
import sys, time
import usb.core, usb.util

VID, PID = 0x3533, 0x5A11

def ebv(n):
    if n >= 192:
        return [(n >> 8) | 192, n & 0xFF]
    return [n]

def frame(cmd, data=b""):
    b = bytearray([0x1F, cmd] + ebv(len(data)) + list(data))
    crc = ~(sum(b[1:])) & 0xFF
    b.append(crc)
    return bytes(b)

def read_response(ep_in, timeout_ms=2000):
    """Read one framed package (may span multiple 64-byte bulk packets)."""
    buf = bytearray()
    deadline = time.time() + timeout_ms / 1000
    while time.time() < deadline:
        try:
            chunk = ep_in.read(64, timeout=200)
            buf.extend(chunk)
        except usb.core.USBError as e:
            if e.errno == 7 or 'timed out' in str(e):
                continue
            raise
        # try to parse
        while len(buf) >= 4:
            if buf[0] != 0x1F:
                buf.pop(0); continue
            if buf[2] >= 192:
                if len(buf) < 4: break
                ln = ((buf[2] & ~192) << 8) | buf[3]
                if len(buf) < ln + 5: break
                return bytes(buf[:ln + 5])
            else:
                ln = buf[2]
                if len(buf) < ln + 4: break
                return bytes(buf[:ln + 4])
    return None

def main():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        print("printer not found"); sys.exit(1)
    dev.reset()
    time.sleep(0.5)
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
    dev.set_configuration()
    intf = dev.get_active_configuration()[(0, 0)]
    ep_out = usb.util.find_descriptor(intf, custom_match=lambda e: e.bEndpointAddress == 0x01)
    ep_in = usb.util.find_descriptor(intf, custom_match=lambda e: e.bEndpointAddress == 0x81)
    print(f"OUT {ep_out.bEndpointAddress:#x} IN {ep_in.bEndpointAddress:#x}")

    queries = {
        113: "PRINTER_DPI",
        114: "PRINTER_WIDTH",
        119: "BUFFER_SIZE",
        112: "IS_PRINTABLE",
        121: "DEVICE_NAME",
        124: "SOFTWARE_VERSION",
        117: "MANUFACTURER",
        120: "DEVICE_TYPE",
        122: "DEVICE_VERSION",
    }
    for cmd, name in queries.items():
        pkt = frame(cmd)
        try:
            n = ep_out.write(pkt, timeout=1000)
        except usb.core.USBError as e:
            print(f"cmd {cmd} {name}: write failed {e}"); continue
        resp = read_response(ep_in, 1500)
        print(f"cmd {cmd} {name}: sent {n}, resp = {resp.hex() if resp else None}"
              + (f"  ascii='{bytes(resp[3:-1]).decode('latin1', 'replace')}'" if resp and len(resp) > 4 else ""))

if __name__ == "__main__":
    main()
