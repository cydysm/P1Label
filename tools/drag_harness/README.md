# P1Label drag measurement harness

Temporary, self-contained harness for objectively measuring the SwiftUI
`LabelCanvas` drag behaviour.  Everything lives under `/tmp/p1harness`; the
user's project and running `P1Label` app are only read, never modified.

## Quick start

```bash
cd /tmp/p1harness
./run.sh /tmp/p1harness/baseline_src /tmp/p1harness/out_baseline
# or, for another source tree:
./run.sh /path/to/Sources /tmp/p1harness/out_fixed
```

`run.sh` copies `<srcdir>/*.swift` into `/tmp/p1harness/src`, comments out the
app's `@main`, adds `HarnessMain.swift`, and compiles to
`/tmp/p1harness/build/p1harness` (swiftc + `-module-cache-path
/tmp/p1harness/mc`; libusb from `/opt/homebrew`).  Then it runs:

1. `--probe` — launches the real `ContentView()` (980×683 content) in an
   `NSHostingView`, waits 1.5 s, captures the window.
2. `probe_target.py` — finds the seeded text element and writes
   `<outdir>/target.json` (grab point, window-base coordinates).
3. `--drag` — mouse down at the grab point, 20 drag events of (+12, +6) pt with
   30 ms run-loop settle each, capture after each; mouse up; 0.4 s; capture.
4. `analyze.py` — writes `<outdir>/analysis_baseline.txt`.
5. `--burst` — same trajectory with 5 ms event spacing/snapshots; analysis in
   `<outdir>/burst` and `<outdir>/analysis_burst.txt`.

Add `--no-burst` (or `HARNESS_BURST=0`) to skip step 5.

Optional fine-step run (supplementary; exposes the sub-dot oscillation that a
fixed build must also eliminate):

```bash
HARNESS_FINE=1 ./run.sh /path/to/Sources /tmp/p1harness/out_fixed
# (runs 60 x (+2,+1) pt into <outdir>/fine; stays inside the paper)

# or manually, any step size:
HARNESS_STEPS=120 HARNESS_STEP_X=2 HARNESS_STEP_Y=1 \
  /tmp/p1harness/build/p1harness --drag <outdir>/target.json /tmp/p1harness/out_fine
/usr/bin/python3 /tmp/p1harness/analyze.py /tmp/p1harness/out_fine
```

## What is seeded

Before `ContentView`/`PrintModel` is created, `HarnessMain` writes
`UserDefaults.standard["P1Label.document"]` (clearing any other `P1Label.*`
keys) with a document containing exactly one text element:

`x=32, y=45, text="拖拽测试", fontSize=30, bold=true, size=96, width=0`
on a 304×240-dot paper (40×30 mm, scale 2.0 pt/dot at the default window size).

## Files

| file | purpose |
|---|---|
| `src/` | build tree: baseline sources + commented `@main` + `HarnessMain.swift` + libusb modulemap/shim |
| `templates/` | clean copies used by `run.sh` to rebuild `src/` |
| `baseline_src/` | untouched snapshot supplied by the caller |
| `build/p1harness` | harness binary (also `p1harness_instr` = diagnostic copy) |
| `analyze.py` | numpy-only paper/cluster/tracking/ghost analysis |
| `probe_target.py` | grab point from the probe frame, prints JSON |
| `run.sh` | build + probe + drag + burst + analysis |
| `out_baseline/` | representative baseline run, analysis text and PNGs |

## Capture format

`<frame>.raw`: little-endian `int32 width`, `int32 height`, then `width*height`
grayscale bytes, row-major **top-down**.  Blue-dominant pixels (the selection
box/handle) are forced to white so they cannot be mistaken for black content;
`<frame>.png` keeps the true colour and is the file to inspect visually.
`window_meta.json`: `frameHeight`, `imageHeightPx`, `scale` (pixels per point),
`windowNumber`, etc.  Pixel→window-base conversion:
`wx = px / k`, `wy = frameHeight - py / k`, with `k = imageHeightPx /
frameHeight`.

## Analysis notes

* Paper: largest pure-white (>=250) region in the right 70%; the pure-white
  interior is 2 pt smaller than the paper frame because of the 1 pt border.
  Scale is derived from the paper height (`480 pt / 240 dots` = 2.0).
* Dark clusters: pixels <100, 4-connected run-length labelling (no scipy),
  filtered below 30 px, then glyphs are merged into line objects with a cheap
  dilation.
* Tracking: element centre (glyph bbox) per frame vs cursor delta.  The
  selection-box centre comes from the harness-recorded blue bbox.
* Ghost check: shift the grab-state text mask by the selection-box
  displacement; any coherent dark pixels left over are a second copy.  A
  synthetic double-exposure test produces 24 531 residual px / 14 components,
  while every measured frame produces 0.  Frames whose text or selection box
  touches the paper edge are flagged as clipped and excluded from the ghost
  check (their position is truncated by the Canvas).
* If the `.raw` files are missing, `analyze.py` falls back to decoding the PNG
  siblings through Quartz (same blue-to-white rule); the PNG fallback
  reproduces the raw-based numbers exactly on the baseline run.

## Caveats

* `CGWindowListCreateImage` costs 35–90 ms per capture on this machine, so the
  "5 ms burst" captures are actually spaced by the capture time (~40–90 ms).
  The burst still shows the settled/catch-up state; a one-frame transient
  shorter than a capture cannot be sampled by this method.
* At the default 980×683 content size the paper is 608 pt wide but the
  ScrollView viewport is ~584 pt, so the right edge of the paper is clipped
  (the paper is horizontally scrollable).  The visible aspect ratio is
  therefore 1.220 instead of 1.267; this is reported, not used to derive scale.
* The harness's `ContentView.onAppear` calls `connect()` exactly like the real
  app; with no reachable printer it fails immediately (`USBError 1`) and does
  not claim any device.
* The shared `/tmp/p1harness` directory was concurrently cleaned of `*.raw`
  files during development; the PNGs and analysis text survive.  Re-running
  `run.sh` regenerates everything.
