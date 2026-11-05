#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later — part of P1Label (GPL-3.0-or-later).
"""Drag an element in the P1Label canvas with synthetic mouse events,
capturing screenshots mid-drag to observe ghosting/artifacts."""
import Quartz, time, subprocess, os, sys

def window_bounds(title_substr="P1"):
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    for w in wins:
        name = w.get('kCGWindowName', '') or ''
        owner = w.get('kCGWindowOwnerName', '') or ''
        if title_substr in name or title_substr in owner:
            b = w['kCGWindowBounds']
            return (b['X'], b['Y'], b['Width'], b['Height'])
    return None

def post(event_type, pos, button=Quartz.kCGMouseButtonLeft):
    e = Quartz.CGEventCreateMouseEvent(None, event_type, pos, button)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)

def move(x, y):
    post(Quartz.kCGEventMouseMoved, (x, y))

def drag(x, y):
    post(Quartz.kCGEventLeftMouseDragged, (x, y))

def down(x, y):
    post(Quartz.kCGEventLeftMouseDown, (x, y))

def up(x, y):
    post(Quartz.kCGEventLeftMouseUp, (x, y))

WIN_ID = 701

def capture(path):
    subprocess.run(['screencapture', '-x', '-o', f'-l{WIN_ID}', path],
                   check=False, capture_output=True)

def main():
    b = window_bounds("P1")
    if not b:
        print("window not found"); sys.exit(1)
    wx, wy, ww, wh = b
    print("window:", b)
    os.makedirs('/tmp/dragframes', exist_ok=True)
    subprocess.run(['rm', '-f', '/tmp/dragframes/*.png'])

    # The canvas occupies roughly the right 60% of the window.
    # "HELLO P1" default element sits near the top-left of the paper.
    canvas_x = wx + int(ww * 0.45)
    canvas_y = wy + int(wh * 0.30)
    # move onto the text element area (top-left of paper)
    sx, sy = canvas_x + 80, canvas_y + 60
    move(sx, sy); time.sleep(0.3)
    down(sx, sy); time.sleep(0.15)

    # slow drag right-down over ~1.2s, capture 8 frames during the drag
    steps = 24
    dx, dy = 500, 260
    for i in range(1, steps + 1):
        x = sx + dx * i / steps
        y = sy + dy * i / steps
        drag(x, y)
        if i % 3 == 0:
            capture(f'/tmp/dragframes/f{i:02d}.png')
        time.sleep(0.05)
    up(sx + dx, sy + dy)
    time.sleep(0.3)
    capture('/tmp/dragframes/f_end.png')
    print("frames:", sorted(os.listdir('/tmp/dragframes')))

if __name__ == "__main__":
    main()
