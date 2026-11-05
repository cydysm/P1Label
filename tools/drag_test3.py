#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later — part of P1Label (GPL-3.0-or-later).
"""Final drag analysis: locate the QR visually, drag it left across open paper,
capture every frame with no delay, diff consecutive frames to expose ghosting."""
import Quartz, time, subprocess, os
from PIL import Image
import numpy as np

def window():
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    for w in wins:
        if (w.get('kCGWindowOwnerName','') or '') == 'P1标签打印':
            b = w['kCGWindowBounds']
            return b['X'], b['Y'], b['Width'], b['Height'], w['kCGWindowNumber']
    raise SystemExit('not found')

def post(t, pos):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap,
                       Quartz.CGEventCreateMouseEvent(None, t, pos, Quartz.kCGMouseButtonLeft))

def find_qr_center(png):
    """QR = dark blob in the upper-right canvas area."""
    a = np.asarray(Image.open(png).convert('L'))
    h, w = a.shape
    region = a[int(h*0.08):int(h*0.55), int(w*0.55):int(w*0.97)]
    dark = region < 100
    ys, xs = np.nonzero(dark)
    if len(xs) < 200:
        return None
    # use median for robustness
    return (int(w*0.55) + int(np.median(xs)), int(h*0.08) + int(np.median(ys)))

def main():
    wx, wy, ww, wh, wid = window()
    os.makedirs('/tmp/frames3', exist_ok=True)
    subprocess.run(['rm', '-f', '/tmp/frames3/*.png'])
    ref = '/tmp/frames3/ref.png'
    subprocess.run(['screencapture', '-x', '-o', f'-l{wid}', ref])
    c = find_qr_center(ref)
    print('qr center (window px):', c)
    gx, gy = wx + c[0]/2, wy + c[1]/2
    post(Quartz.kCGEventMouseMoved, (gx, gy)); time.sleep(0.4)
    post(Quartz.kCGEventLeftMouseDown, (gx, gy)); time.sleep(0.15)
    n = 30
    for i in range(1, n+1):
        post(Quartz.kCGEventLeftMouseDragged, (gx - 360*i/n, gy + 60*i/n))
        subprocess.run(['screencapture', '-x', '-o', f'-l{wid}', f'/tmp/frames3/d{i:02d}.png'],
                       check=False)
    post(Quartz.kCGEventLeftMouseUp, (gx-360, gy+60))
    time.sleep(0.4)
    subprocess.run(['screencapture', '-x', '-o', f'-l{wid}', '/tmp/frames3/end.png'])

    # analysis: for each frame find QR center; check double-image via dark-pixel spread
    centers = []
    for i in range(1, n+1):
        p = f'/tmp/frames3/d{i:02d}.png'
        c2 = find_qr_center(p)
        centers.append(c2)
    print('qr centers over frames:')
    prev = None
    for i, cc in enumerate(centers, 1):
        d = '' if prev is None else f'd=({cc[0]-prev[0]:+d},{cc[1]-prev[1]:+d})'
        print(f'  f{i:02d}: {cc} {d}')
        prev = cc

if __name__ == '__main__':
    main()
