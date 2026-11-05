#!/usr/bin/env python3
"""Compute the grab point (window-base points) from the probe window capture.

The grab point is the centre of the dark text cluster on the paper.  Prints a
single JSON object on stdout (progress goes to stderr), e.g.
  {"x": 547.75, "y": 492.25, "scale": 2.0, ...}
"""

import json
import os
import sys

import analyze as A


def main():
    if len(sys.argv) < 2:
        print("usage: probe_target.py <outdir>", file=sys.stderr)
        return 2
    outdir = sys.argv[1]
    meta = A.find_meta(outdir)
    path = None
    name = None
    for cand in ("probe.raw", "frame_before.raw", "probe.png", "frame_before.png"):
        p = os.path.join(outdir, cand)
        if os.path.exists(p):
            path, name = p, cand.rsplit(".", 1)[0]
            break
    if path is None:
        print("probe_target: no probe/frame_before raw or png in %s" % outdir, file=sys.stderr)
        return 3

    img = A.load_image(path)
    paper = A.detect_paper(img, meta)
    geom = A.Geometry(meta, paper["x0"], paper["x1"], paper["y0"], paper["y1"], paper["scale"])
    fa = A.analyze_frame(name, path, geom)
    if not fa.text:
        print("probe_target: no dark text object found", file=sys.stderr)
        return 4
    center = A.object_center_window(fa, fa.text)
    bbox = A.object_bbox_window(fa, fa.text)
    dots = geom.px_to_dots(geom.paper_x0px + fa.text["cx"],
                           geom.paper_y0px + fa.text["cy"])
    result = {
        "x": center[0],
        "y": center[1],
        "source": name,
        "scale": geom.scale,
        "paper_bbox_window": [geom.paper_left_pt, geom.paper_top_base,
                              geom.paper_left_pt + paper["visible_w_pt"],
                              geom.paper_bottom_base],
        "text_bbox_window": list(bbox),
        "text_center_dots": list(dots),
        "dark_objects": len(fa.objects),
        "object_aspect": fa.text["aspect"],
        "object_dark_px": fa.text["dark"],
    }
    print(json.dumps(result))
    print("probe_target: grab at (%.2f, %.2f) window pts, scale %.4f, paper bbox %s"
          % (center[0], center[1], geom.scale, result["paper_bbox_window"]), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
