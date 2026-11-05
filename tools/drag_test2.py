#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later — part of P1Label (GPL-3.0-or-later).
"""Precise drag test: locate the HELLO P1 text on screen, drag it, capture every frame,
and analyze whether the canvas repaints per frame (ghosting = text visible at 2+ positions)."""
import Quartz, time, subprocess, os
from PIL import Image

WIN_ID = 701

def shot(path):
    subprocess.run(['screencapture', '-x', '-o', f'-l{WIN_ID}', path],
                   check=False, capture_output=True)

def post(event_type, pos):
    e = Quartz.CGEventCreateMouseEvent(None, event_type, pos, Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)

def window_bounds():
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    for w in wins:
        if (w.get('kCGWindowOwnerName','') or '') == 'P1标签打印':
            b = w['kCGWindowBounds']
            return b['X'], b['Y'], b['Width'], b['Height'], w['kCGWindowNumber']
    return None

def find_text_center(png):
    """Find the HELLO P1 text: dark pixels in the canvas area, take the largest cluster."""
    img = Image.open(png).convert('L')
    w, h = img.size  # retina pixels (2x logical for the window? window is 980x683 logical)
    px = img.load()
    # canvas = right half, upper area
    xs, ys = [], []
    for y in range(int(h*0.15), int(h*0.45), 2):
        for x in range(int(w*0.40), int(w*0.80), 2):
            if px[x, y] < 60:
                xs.append(x); ys.append(y)
    if not xs:
        return None
    return sum(xs)//len(xs), sum(ys)//len(ys)

def main():
    wb = window_bounds()
    print("window:", wb)
    os.makedirs('/tmp/frames2', exist_ok=True)
    subprocess.run(['rm', '-f', '/tmp/frames2/*.png'])
    ref = '/tmp/frames2/ref.png'
    shot(ref)
    center = find_text_center(ref)
    if not center:
        print("text not found"); return
    cx, cy = center
    print("text center(px in window):", cx, cy)
    # window logical coords -> global
    wx, wy, ww, wh, _ = wb
    # capture is retina 2x: logical = px/2
    gx = wx + cx/2
    gy = wy + cy/2
    print("global start:", gx, gy)

    post(Quartz.kCGEventMouseMoved, (gx, gy)); time.sleep(0.4)
    post(Quartz.kCGEventLeftMouseDown, (gx, gy)); time.sleep(0.2)
    n = 40
    for i in range(1, n+1):
        x = gx + 300*i/n
        y = gy + 140*i/n
        post(Quartz.kCGEventLeftMouseDragged, (x, y))
        shot(f'/tmp/frames2/d{i:02d}.png')
        time.sleep(0.04)
    post(Quartz.kCGEventLeftMouseUp, (gx+300, gy+140))
    time.sleep(0.5)
    shot('/tmp/frames2/end.png')

    # analysis: for each frame, find dark clusters in canvas -> report distinct positions
    positions = []
    for i in range(1, n+1):
        c = find_text_center(f'/tmp/frames2/d{i:02d}.png')
        positions.append(c)
    uniq = []
    for p in positions:
        if not uniq or (abs(p[0]-uniq[-1][0]) > 6 or abs(p[1]-uniq[-1][1]) > 6):
            uniq.append(p)
    print(f"frames: {n}, distinct canvas text positions: {len(uniq)}")
    for u in uniq[:12]:
        print("  ", u)

if __name__ == '__main__':
    main()
