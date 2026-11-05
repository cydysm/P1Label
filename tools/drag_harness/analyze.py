#!/usr/bin/env python3
"""Analyze raw frames captured by the P1Label drag harness.

Pure numpy (no scipy/PIL).  Coordinates:
  * image px, top-down, captured at k = imageHeightPx / frameHeight (2.0 here)
  * window base points (bottom-left origin) as needed by NSEvent
  * paper dots (304 x 240) with the paper's top-left frame corner as origin

Blue pixels (selection box / handle) are already forced to white in the .raw
files by the harness; the original colour is kept in the .png siblings and the
harness also records the blue bbox per frame in drag_log.json.
"""

import json
import os
import struct
import sys

import numpy as np

PAPER_W_DOTS = 304
PAPER_H_DOTS = 240
DARK_THRESHOLD = 100
MIN_COMPONENT_PX = 30


# --------------------------------------------------------------------------- #
# raw / metadata
# --------------------------------------------------------------------------- #

def read_raw(path):
    with open(path, "rb") as f:
        header = f.read(8)
        if len(header) != 8:
            raise ValueError("short raw header: %s" % path)
        w, h = struct.unpack("<ii", header)
        buf = np.frombuffer(f.read(), dtype=np.uint8)
    if buf.size != w * h:
        raise ValueError("%s: expected %d bytes, got %d" % (path, w * h, buf.size))
    return buf.reshape(h, w)


def read_png_gray(path):
    """Fallback when a concurrent cleanup removed the .raw file.

    Uses Quartz (available in /usr/bin/python3) to decode the PNG, then applies
    the same grayscale rule as the harness: blue-dominant selection chrome is
    forced to white, everything else is luminance.
    """
    import Quartz
    url = Quartz.CFURLCreateFromFileSystemRepresentation(None, path.encode(), len(path), False)
    src = Quartz.CGImageSourceCreateWithURL(url, None)
    if src is None:
        raise IOError("cannot open %s" % path)
    img = Quartz.CGImageSourceCreateImageAtIndex(src, 0, None)
    if img is None:
        raise IOError("cannot decode %s" % path)
    w = Quartz.CGImageGetWidth(img)
    h = Quartz.CGImageGetHeight(img)
    bpr = Quartz.CGImageGetBytesPerRow(img)
    data = Quartz.CGDataProviderCopyData(Quartz.CGImageGetDataProvider(img))
    if data is None:
        raise IOError("no pixel data in %s" % path)
    arr = np.frombuffer(bytes(data), dtype=np.uint8)
    arr = arr[:bpr * h].reshape(h, bpr)[:, :w * 4].reshape(h, w, 4)
    r = arr[:, :, 0].astype(np.int32)
    g = arr[:, :, 1].astype(np.int32)
    b = arr[:, :, 2].astype(np.int32)
    blue = (b > r + 25) & (b > g + 25)
    gray = ((299 * r + 587 * g + 114 * b) // 1000).astype(np.uint8)
    gray[blue] = 255
    return gray


def load_image(path):
    """Load a frame given a .raw or .png path; fall back to the sibling .png."""
    if path.endswith(".png"):
        return read_png_gray(path)
    if os.path.exists(path):
        return read_raw(path)
    alt = path[:-4] + ".png"
    if os.path.exists(alt):
        return read_png_gray(alt)
    raise IOError("missing frame: %s (and %s)" % (path, alt))


def load_json(path):
    with open(path, "r") as f:
        return json.load(f)


def find_meta(outdir):
    for path in (os.path.join(outdir, "window_meta.json"),
                 "/tmp/p1harness/window_meta.json"):
        if os.path.exists(path):
            return load_json(path)
    raise SystemExit("no window_meta.json in %s" % outdir)


# --------------------------------------------------------------------------- #
# paper detection
# --------------------------------------------------------------------------- #

def _longest_run(indices):
    if len(indices) == 0:
        return np.array([], dtype=int)
    breaks = np.where(np.diff(indices) > 1)[0]
    starts = np.r_[0, breaks + 1]
    ends = np.r_[breaks, len(indices) - 1]
    lens = ends - starts
    best = int(np.argmax(lens))
    return indices[starts[best]:ends[best] + 1]


class Geometry:
    def __init__(self, meta, x0, x1, y0, y1, scale):
        self.meta = meta
        self.frame_h = float(meta["frameHeight"])
        self.frame_w = float(meta["frameWidth"])
        self.k = float(meta["imageHeightPx"]) / self.frame_h
        self.paper_x0px = x0
        self.paper_x1px = x1
        self.paper_y0px = y0
        self.paper_y1px = y1
        self.scale = scale                      # window points per paper dot
        # paper frame (border included) origin, top-down points
        self.paper_left_pt = x0 / self.k - 1.0
        self.paper_top_pt = y0 / self.k - 1.0
        # in window base coordinates (bottom-left origin)
        self.paper_top_base = self.frame_h - self.paper_top_pt
        self.paper_bottom_base = self.frame_h - (y1 / self.k + 1.0)

    def px_to_window(self, x, y):
        return (x / self.k, self.frame_h - y / self.k)

    def px_to_dots(self, x, y):
        dx = ((x - self.paper_x0px) / self.k + 1.0) / self.scale
        dy = ((y - self.paper_y0px) / self.k + 1.0) / self.scale
        return (dx, dy)

    def px_per_dot(self):
        return self.scale * self.k


def detect_paper(img, meta):
    h, w = img.shape
    white = img >= 250
    x_start = int(round(w * 0.30))  # canvas is the right pane (editor is narrower)
    sub = white[:, x_start:]
    row_counts = sub.sum(axis=1).astype(np.int64)
    col_counts = sub.sum(axis=0).astype(np.int64)
    if row_counts.max() < 50 or col_counts.max() < 50:
        raise SystemExit("could not find a white paper area in the right pane")
    rows = _longest_run(np.where(row_counts > 0.5 * row_counts.max())[0])
    cols = _longest_run(np.where(col_counts > 0.5 * col_counts.max())[0])
    y0, y1 = int(rows[0]), int(rows[-1])
    x0, x1 = int(x_start + cols[0]), int(x_start + cols[-1])

    k = float(meta["imageHeightPx"]) / float(meta["frameHeight"])
    interior_h_pt = (y1 - y0 + 1) / k
    interior_w_pt = (x1 - x0 + 1) / k
    # SwiftUI .border(width: 1) is drawn just inside the 1x frame; the pure-white
    # interior is 2 pt smaller in each dimension.
    paper_h_pt = interior_h_pt + 2.0
    scale = paper_h_pt / PAPER_H_DOTS
    full_w_pt = PAPER_W_DOTS * scale
    visible_w_pt = interior_w_pt + 2.0
    clipped = visible_w_pt < full_w_pt - 1.5
    aspect_visible = interior_w_pt / interior_h_pt
    full_aspect = (PAPER_W_DOTS / PAPER_H_DOTS)
    return {
        "x0": x0, "x1": x1, "y0": y0, "y1": y1,
        "scale": scale,
        "interior_w_pt": interior_w_pt,
        "interior_h_pt": interior_h_pt,
        "full_w_pt": full_w_pt,
        "visible_w_pt": visible_w_pt,
        "clipped": clipped,
        "aspect_visible": aspect_visible,
        "aspect_expected": full_aspect,
    }


def describe_paper(paper):
    print("paper (white interior) px: x %d..%d  y %d..%d  => %.1f x %.1f pt"
          % (paper["x0"], paper["x1"], paper["y0"], paper["y1"],
             paper["visible_w_pt"], paper["interior_h_pt"]))
    print("canvas scale: %.4f pt/dot (paper height %.1f pt / %d dots)"
          % (paper["scale"], paper["interior_h_pt"] + 2.0, PAPER_H_DOTS))
    print("paper aspect: visible %.3f, expected %.3f%s"
          % (paper["aspect_visible"], paper["aspect_expected"],
             "  [paper clipped on the right by the ScrollView]" if paper["clipped"] else ""))
    if not paper["clipped"] and abs(paper["aspect_visible"] - paper["aspect_expected"]) > 0.03:
        print("WARNING: paper aspect ratio is off by more than 0.03")


# --------------------------------------------------------------------------- #
# connected components (run-length + union find, 4-connectivity)
# --------------------------------------------------------------------------- #

def components(mask, min_area=MIN_COMPONENT_PX):
    h, w = mask.shape
    parent = {}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    row_runs = []
    prev = []
    next_id = 0
    for y in range(h):
        xs = np.flatnonzero(mask[y])
        cur = []
        if xs.size:
            gaps = np.where(np.diff(xs) > 1)[0]
            starts = np.r_[0, gaps + 1]
            ends = np.r_[gaps, len(xs) - 1]
            for st, en in zip(starts, ends):
                s = int(xs[st])
                e = int(xs[en])
                touched = [lab for (ps, pe, lab) in prev if ps <= e and pe >= s]
                if touched:
                    lab = find(touched[0])
                    for t in touched[1:]:
                        union(lab, find(t))
                    lab = find(lab)
                else:
                    lab = next_id
                    parent[lab] = lab
                    next_id += 1
                cur.append((s, e, lab))
        row_runs.append(cur)
        prev = cur

    agg = {}
    for y, runs in enumerate(row_runs):
        for s, e, lab in runs:
            r = find(lab)
            d = agg.get(r)
            if d is None:
                agg[r] = [s, e, y, y, e - s + 1]
            else:
                d[0] = min(d[0], s)
                d[1] = max(d[1], e)
                d[2] = min(d[2], y)
                d[3] = max(d[3], y)
                d[4] += e - s + 1

    out = []
    for (x0, x1, y0, y1, area) in agg.values():
        if area >= min_area:
            out.append({"x0": x0, "x1": x1, "y0": y0, "y1": y1,
                        "area": int(area),
                        "w": x1 - x0 + 1, "h": y1 - y0 + 1,
                        "cx": (x0 + x1) / 2.0, "cy": (y0 + y1) / 2.0})
    out.sort(key=lambda c: -c["area"])
    return out


def dilate_rect(mask, rx, ry):
    m = mask.copy()
    src = mask
    for d in range(1, rx + 1):
        m[:, d:] |= src[:, :-d]
        m[:, :-d] |= src[:, d:]
    src2 = m.copy()
    for d in range(1, ry + 1):
        m[d:, :] |= src2[:-d, :]
        m[:-d, :] |= src2[d:, :]
    return m


def objects_from_mask(mask, rx=6, ry=4, min_dark=MIN_COMPONENT_PX):
    """Merge glyph sub-components into text-line objects via cheap dilation."""
    dil = dilate_rect(mask, rx, ry)
    comps = components(dil, min_area=1)
    dark = mask
    objs = []
    for c in comps:
        x0 = max(0, c["x0"] + rx)
        x1 = min(mask.shape[1] - 1, c["x1"] - rx)
        y0 = max(0, c["y0"] + ry)
        y1 = min(mask.shape[0] - 1, c["y1"] - ry)
        if x1 <= x0 or y1 <= y0:
            x0, x1, y0, y1 = c["x0"], c["x1"], c["y0"], c["y1"]
        dark_count = int(dark[y0:y1 + 1, x0:x1 + 1].sum())
        if dark_count < min_dark:
            continue
        objs.append({"x0": x0, "x1": x1, "y0": y0, "y1": y1,
                     "dark": dark_count,
                     "w": x1 - x0 + 1, "h": y1 - y0 + 1,
                     "cx": (x0 + x1) / 2.0, "cy": (y0 + y1) / 2.0,
                     "aspect": (x1 - x0 + 1) / max(1.0, y1 - y0 + 1)})
    objs.sort(key=lambda o: -o["dark"])
    return objs


# --------------------------------------------------------------------------- #
# frame analysis
# --------------------------------------------------------------------------- #

class FrameAnalysis:
    def __init__(self, name, img, geom):
        self.name = name
        self.geom = geom
        x0, x1 = geom.paper_x0px, geom.paper_x1px
        y0, y1 = geom.paper_y0px, geom.paper_y1px
        self.dark = img[y0:y1 + 1, x0:x1 + 1] < DARK_THRESHOLD
        # text touching the paper boundary is clipped by the Canvas; positions
        # and ghost residual are biased in that case
        self.clipped = bool(self.dark[0, :].any() or self.dark[-1, :].any()
                            or self.dark[:, 0].any() or self.dark[:, -1].any())
        self.objects = objects_from_mask(self.dark)
        self.text = None
        if self.objects:
            flat = [o for o in self.objects if o["aspect"] > 2.5 and o["w"] > 40]
            self.text = max(flat, key=lambda o: o["dark"]) if flat else self.objects[0]


def analyze_frame(name, path, geom):
    img = load_image(path)
    if img.shape[1] != int(geom.meta["imageWidthPx"]):
        print("WARNING: %s image width %d != meta %d"
              % (name, img.shape[1], geom.meta["imageWidthPx"]))
    return FrameAnalysis(name, img, geom)


def object_center_window(fa, obj):
    x0 = fa.geom.paper_x0px + obj["x0"]
    x1 = fa.geom.paper_x0px + obj["x1"]
    y0 = fa.geom.paper_y0px + obj["y0"]
    y1 = fa.geom.paper_y0px + obj["y1"]
    return fa.geom.px_to_window((x0 + x1) / 2.0, (y0 + y1) / 2.0)


def object_bbox_window(fa, obj):
    x0 = fa.geom.paper_x0px + obj["x0"]
    x1 = fa.geom.paper_x0px + obj["x1"]
    y0 = fa.geom.paper_y0px + obj["y0"]
    y1 = fa.geom.paper_y0px + obj["y1"]
    wx0, wy1 = fa.geom.px_to_window(x0, y0)
    wx1, wy0 = fa.geom.px_to_window(x1, y1)
    return (wx0, wy0, wx1, wy1)


def blue_center_px(step):
    b = step.get("blueBBoxPx")
    if not b:
        return None
    return ((b["x0"] + b["x1"]) / 2.0, (b["y0"] + b["y1"]) / 2.0)


def main():
    if len(sys.argv) < 2:
        print("usage: analyze.py <outdir>")
        return 2
    outdir = sys.argv[1]
    meta = find_meta(outdir)
    log_path = os.path.join(outdir, "drag_log.json")
    log = load_json(log_path) if os.path.exists(log_path) else None

    first_path = None
    for cand in ("frame_before.raw", "probe.raw", "frame_before.png", "probe.png"):
        p = os.path.join(outdir, cand)
        if os.path.exists(p):
            first_path = p
            break
    if not first_path:
        raise SystemExit("no frame_before/probe raw or png in %s" % outdir)

    first_img = load_image(first_path)
    paper = detect_paper(first_img, meta)
    geom = Geometry(meta, paper["x0"], paper["x1"], paper["y0"], paper["y1"], paper["scale"])
    describe_paper(paper)
    print("window base height: %.1f pt, px/point k=%.3f, px/dot=%.2f"
          % (geom.frame_h, geom.k, geom.px_per_dot()))

    # sanity-check that paper origin is sane relative to the window
    print("paper top-left in window base coords: (%.1f, %.1f)"
          % (geom.paper_left_pt, geom.paper_top_base))

    fa_first = analyze_frame("frame_before" if "frame_before" in first_path else "probe",
                             first_path, geom)
    if fa_first.text is None:
        raise SystemExit("no dark text object found in %s" % first_path)
    print("dark objects in first frame: %d" % len(fa_first.objects))
    for i, o in enumerate(fa_first.objects):
        b = object_bbox_window(fa_first, o)
        print("  obj %d: bbox window (%.1f,%.1f)-(%.1f,%.1f) aspect %.2f dark=%d"
              % (i, b[0], b[1], b[2], b[3], o["aspect"], o["dark"]))
    first_center = object_center_window(fa_first, fa_first.text)
    print("tracked text center (window pts): (%.2f, %.2f)" % first_center)

    if log is None:
        print("no drag_log.json; stop after paper/object sanity check")
        return 0

    target = (float(log["target"]["x"]), float(log["target"]["y"]))
    scale = geom.scale
    ppd = geom.px_per_dot()

    # Reference for overlay position: selection-box centre in frame_grab.
    grab = log.get("grabFrame", {})
    grab_blue = blue_center_px(grab)
    grab_path = os.path.join(outdir, "frame_grab.raw")
    grab_fa = analyze_frame("frame_grab", grab_path, geom) if (
        os.path.exists(grab_path) or os.path.exists(grab_path[:-4] + ".png")) else None
    base_mask = grab_fa.dark if grab_fa is not None else fa_first.dark

    frames = []
    steps = log.get("steps", [])
    seen = set()
    for step in steps:
        name = step["frame"]
        path = os.path.join(outdir, name + ".raw")
        if not (os.path.exists(path) or os.path.exists(path[:-4] + ".png")):
            print("WARNING: missing %s" % path)
            continue
        fa = analyze_frame(name, path, geom)
        frames.append((step, fa))
        seen.add(name)
    for tail in log.get("tailFrames", []):
        name = tail["frame"]
        if name in seen:
            continue
        path = os.path.join(outdir, name + ".raw")
        if os.path.exists(path) or os.path.exists(path[:-4] + ".png"):
            frames.append((tail, analyze_frame(name, path, geom)))
    end = log.get("endFrame")
    end_fa = None
    end_raw = os.path.join(outdir, "frame_end.raw")
    if end and (os.path.exists(end_raw) or os.path.exists(end_raw[:-4] + ".png")):
        end_fa = analyze_frame("frame_end", end_raw, geom)

    print()
    print("=== drag tracking (%s) ===" % log.get("mode", "?"))
    header = ("step  cursorΔ(x,y)   objΔ(x,y)   ratio     err(cursor)      "
              "err(grid)    objs  ghostpx  boxΔ(x,y)")
    print(header)
    print("-" * len(header))

    prev_center = first_center
    tracked = []
    warned_ratio = False
    clipped_frames = 0
    for step, fa in frames:
        cursor = (float(step["cursorX"]), float(step["cursorY"]))
        cdx = cursor[0] - target[0]
        cdy = cursor[1] - target[1]
        if fa.text is None:
            print("%-5s no dark object" % step["frame"])
            continue
        # Track the object closest to the previous tracked position, preferring
        # flat text-line shaped objects.
        cands = [o for o in fa.objects if o["aspect"] > 1.8] or fa.objects
        obj = min(cands, key=lambda o: (object_center_window(fa, o)[0] - prev_center[0]) ** 2
                  + (object_center_window(fa, o)[1] - prev_center[1]) ** 2)
        center = object_center_window(fa, obj)
        prev_center = center
        odx = center[0] - first_center[0]
        ody = center[1] - first_center[1]
        ratio = odx / cdx if abs(cdx) > 1e-6 else float("nan")
        ex = target[0] + cdx
        ey = target[1] + cdy
        err = (ex - center[0], ey - center[1])
        qx = round(cdx / scale) * scale
        qy = round(cdy / scale) * scale
        qerr = (target[0] + qx - center[0], target[1] + qy - center[1])

        blue = blue_center_px(step)
        boxd = (float("nan"), float("nan"))
        box_center = None
        box_clipped = False
        if blue:
            box_center = geom.px_to_window(blue[0], blue[1])
            b = step.get("blueBBoxPx") or {}
            box_clipped = (b.get("x0", 1e9) <= geom.paper_x0px + 2
                           or b.get("y0", 1e9) <= geom.paper_y0px + 2
                           or b.get("x1", -1) >= geom.paper_x1px - 2
                           or b.get("y1", -1) >= geom.paper_y1px - 2)
        if blue and grab_blue:
            boxd = ((blue[0] - grab_blue[0]) / geom.k, -(blue[1] - grab_blue[1]) / geom.k)

        if fa.clipped or box_clipped:
            ghost_px, ghost_objs = 0, []
            clipped_frames += 1
        else:
            ghost_px, ghost_objs = ghost_residual(fa, base_mask, grab_blue, blue, ppd, geom)
        tracked.append({
            "frame": step["frame"], "cursor": cursor, "cdx": cdx, "cdy": cdy,
            "center": center, "odx": odx, "ody": ody,
            "ratio": ratio, "err": err, "qerr": qerr,
            "objs": len(fa.objects), "ghost_px": ghost_px,
            "ghost_objs": ghost_objs, "boxd": boxd,
            "box_center": box_center,
            "clipped": fa.clipped or box_clipped,
            "obj": obj,
        })
        print("%-5s (%6.1f,%5.1f) (%6.1f,%5.1f) %5.3f  (%6.2f,%6.2f)  "
              "(%5.2f,%5.2f)  %3d  %7d  (%5.1f,%5.1f)"
              % (step["frame"].replace("frame_", ""), cdx, cdy, odx, ody, ratio,
                 err[0], err[1], qerr[0], qerr[1], len(fa.objects), ghost_px,
                 boxd[0], boxd[1]))
        if not warned_ratio and abs(cdx) > 40 and abs(ratio - 1.0) > 0.15:
            warned_ratio = True
            print("  ^ tracking ratio deviates from 1.0 by >15%% at |cursor dx|>40 pt")
        if ghost_objs:
            print("    ghost residual components: %s"
                  % ", ".join("bbox dots %.1f,%.1f..%.1f,%.1f (%dpx)"
                              % (g["x0"], g["y0"], g["x1"], g["y1"], g["area"])
                              for g in ghost_objs))

    # Detailed positions per captured frame (window points and paper dots).
    print()
    print("=== per-frame positions ===")
    print("frame        centre(window pt)    paper dots       box centre(window pt)")
    for t in tracked:
        cd = t["center"]
        # text centre in paper dots from the tracked object bbox
        obj = t["obj"]
        cxd, cyd = geom.px_to_dots(
            geom.paper_x0px + (obj["x0"] + obj["x1"]) / 2.0,
            geom.paper_y0px + (obj["y0"] + obj["y1"]) / 2.0)
        bc = t.get("box_center")
        print("%-11s (%7.2f,%7.2f)  (%7.2f,%7.2f)    %s"
              % (t["frame"], cd[0], cd[1], cxd, cyd,
                 "n/a" if bc is None else "(%.2f,%.2f)" % (bc[0], bc[1])))

    # Summary
    if tracked:
        ratios = [t["ratio"] for t in tracked if abs(t["cdx"]) > 20]
        if ratios:
            print()
            print("tracking ratio (cursor dx > 20 pt): min %.3f max %.3f mean %.3f"
                  % (min(ratios), max(ratios), sum(ratios) / len(ratios)))
        max_err = max(max(abs(t["err"][0]), abs(t["err"][1])) for t in tracked)
        max_qerr = max(max(abs(t["qerr"][0]), abs(t["qerr"][1])) for t in tracked)
        max_ghost = max(t["ghost_px"] for t in tracked)
        print("max |tracking error| vs cursor: %.2f pt ; vs dot grid: %.2f pt ; "
              "max ghost residual: %d px" % (max_err, max_qerr, max_ghost))
        if clipped_frames:
            print("note: %d frame(s) had the text or selection box touching the "
                  "paper edge; positions there are clipped and the ghost check "
                  "was skipped for them" % clipped_frames)
        # show largest frame-to-frame jump in observed movement
        print("object count per frame: %s" % ", ".join(str(t["objs"]) for t in tracked))
        print("ghost px per frame:    %s" % ", ".join(str(t["ghost_px"]) for t in tracked))

    # Final committed frame
    if end_fa is not None:
        final_delta = ((frames[-1][0]["cursorX"] - target[0]) if frames else 240.0,
                       (frames[-1][0]["cursorY"] - target[1]) if frames else 120.0)
        cursor_final = (target[0] + final_delta[0], target[1] + final_delta[1])
        center = object_center_window(end_fa, end_fa.text) if end_fa.text else None
        print()
        print("=== final frame (after mouseUp + 0.4 s) ===")
        print("dark objects: %d" % len(end_fa.objects))
        if center is None:
            print("NO text object visible after commit!")
        else:
            obs_dx = center[0] - first_center[0]
            obs_dy = center[1] - first_center[1]
            exp_dx = cursor_final[0] - target[0]
            exp_dy = cursor_final[1] - target[1]
            print("final cursor delta: (%.1f, %.1f) pt; observed element delta: (%.1f, %.1f) pt"
                  % (exp_dx, exp_dy, obs_dx, obs_dy))
            dots = geom.px_to_dots(geom.paper_x0px + end_fa.text["cx"],
                                   geom.paper_y0px + end_fa.text["cy"])
            first_dots = geom.px_to_dots(geom.paper_x0px + fa_first.text["cx"],
                                         geom.paper_y0px + fa_first.text["cy"])
            obs_dot_dx = (obs_dx) / scale
            obs_dot_dy = -(obs_dy) / scale          # window +y is up, paper dot +y is down
            exp_dot_dx = exp_dx / scale
            exp_dot_dy = -exp_dy / scale
            model_x = 32 + obs_dot_dx
            model_y = 45 + obs_dot_dy
            exp_x = 32 + exp_dot_dx
            exp_y = max(0, 45 + exp_dot_dy)          # onEnded clamps y to >= 0
            print("final text-centre paper-relative dot position: (%.2f, %.2f) dots"
                  % dots)
            print("first text-centre dot position: (%.2f, %.2f) dots"
                  % (first_dots[0], first_dots[1]))
            print("observed dot shift: (%+.2f, %+.2f) dots; expected for 1:1 drag: (%+.2f, %+.2f) dots"
                  % (obs_dot_dx, obs_dot_dy, exp_dot_dx, exp_dot_dy))
            print("committed model position (inferred): x=%d y=%d  (x shifted by %+.2f dots, y by %+.2f)"
                  % (round(model_x), round(model_y), obs_dot_dx, obs_dot_dy))
            print("expected model position for 1:1 tracking: x=%d y=%d  -> commit missed (%.1f, %.1f) dots"
                  % (round(exp_x), round(exp_y), exp_x - model_x, exp_y - model_y))
            print("commit error in window points: (%.2f, %.2f) pt"
                  % (exp_dx - obs_dx, exp_dy - obs_dy))
        if end_fa.text:
            blue_end = blue_center_px(end or {})
            if blue_end:
                bx, by = geom.px_to_window(blue_end[0], blue_end[1])
                print("selection box centre (window pts): (%.2f, %.2f); text centre: (%.2f, %.2f)"
                      % (bx, by, center[0] if center else float("nan"),
                         center[1] if center else float("nan")))

    # Per-frame box vs text centre discrepancy is a strong ghost/desync signal.
    diffs = []
    for t in tracked:
        if t.get("clipped"):
            continue
        if t["boxd"][0] == t["boxd"][0]:  # not NaN
            diffs.append((t["boxd"][0] - t["odx"], t["boxd"][1] - t["ody"], t["frame"]))
    if diffs:
        worst = max(diffs, key=lambda d: max(abs(d[0]), abs(d[1])))
        print()
        print("box-delta minus text-delta (worst): (%.2f, %.2f) pt on %s"
              % (worst[0], worst[1], worst[2]))
        print("median |box-text| desync: (%.2f, %.2f) pt"
              % (float(np.median([abs(d[0]) for d in diffs])),
                 float(np.median([abs(d[1]) for d in diffs]))))
    return 0


def ghost_residual(fa, base_mask, grab_blue, blue, ppd, geom):
    """Shift the grab-state text mask by the selection-box displacement and
    count dark pixels in this frame that the shift does not explain."""
    if grab_blue is None or blue is None:
        return 0, []
    sdx = (blue[0] - grab_blue[0]) / ppd
    sdy = (blue[1] - grab_blue[1]) / ppd
    # integer dot shift (the app previews on the dot grid)
    idx = int(round(sdx))
    idy = int(round(sdy))
    shift_x = int(round(idx * ppd))
    shift_y = int(round(idy * ppd))
    h, w = fa.dark.shape
    shifted = np.zeros_like(fa.dark)
    if abs(shift_x) < w and abs(shift_y) < h:
        src = base_mask
        dst_x0 = max(0, shift_x)
        dst_x1 = min(w, w + shift_x)
        dst_y0 = max(0, shift_y)
        dst_y1 = min(h, h + shift_y)
        src_x0 = dst_x0 - shift_x
        src_x1 = dst_x1 - shift_x
        src_y0 = dst_y0 - shift_y
        src_y1 = dst_y1 - shift_y
        if dst_x1 > dst_x0 and dst_y1 > dst_y0:
            shifted[dst_y0:dst_y1, dst_x0:dst_x1] = src[src_y0:src_y1, src_x0:src_x1]
    residual = fa.dark & ~shifted
    # ignore the selection box's own 2-pt frame area? box is forced white already
    comps = components(residual, min_area=40)
    # only count coherent pieces, and ignore a thin 1-2 px halo around shifted glyphs
    ghost = []
    for c in comps:
        if c["area"] < 40:
            continue
        if c["w"] <= 3 or c["h"] <= 3:
            continue
        ghost.append(c)
    total = int(sum(c["area"] for c in ghost))
    dots = []
    for c in ghost:
        x0, y0 = geom.px_to_dots(geom.paper_x0px + c["x0"], geom.paper_y0px + c["y0"])
        x1, y1 = geom.px_to_dots(geom.paper_x0px + c["x1"], geom.paper_y0px + c["y1"])
        dots.append({"x0": x0, "y0": y0, "x1": x1, "y1": y1, "area": c["area"]})
    return total, dots


if __name__ == "__main__":
    sys.exit(main())
