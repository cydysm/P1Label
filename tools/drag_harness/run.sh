#!/bin/bash
# P1Label drag-measurement harness.
#
#   ./run.sh <source-dir> <outdir> [--no-burst]
#
# Copies <source-dir>/*.swift into /tmp/p1harness/src, disables the app's
# @main, adds HarnessMain.swift, compiles to /tmp/p1harness/build/p1harness,
# then: probe -> target -> drag -> analyze -> burst -> analyze.
#
# Everything the harness writes stays under /tmp/p1harness.  CFFIXED_USER_HOME
# keeps UserDefaults (seed document) out of ~/Library/Preferences.
set -euo pipefail

ROOT=/tmp/p1harness
if [ $# -lt 2 ]; then
    echo "usage: $0 <source-dir> <outdir> [--no-burst]" >&2
    exit 2
fi
SRC=$(cd "$1" && pwd)
OUT=$2
# make OUT absolute (relative paths are relative to the caller's cwd)
case "$OUT" in
    /*) ;;
    *) OUT="$PWD/$OUT" ;;
esac
if [ "$OUT" = "$ROOT" ]; then
    echo "refusing to use /tmp/p1harness itself as outdir" >&2
    exit 2
fi
RUN_BURST=1
if [ "${3:-}" = "--no-burst" ] || [ "${HARNESS_BURST:-1}" = "0" ]; then
    RUN_BURST=0
fi

BUILD=$ROOT/build
BIN=$BUILD/p1harness
WORK=$ROOT/src
MC=$ROOT/mc
SWIFTC=${SWIFTC:-swiftc}
PY=/usr/bin/python3
export CFFIXED_USER_HOME=$ROOT/prefs
mkdir -p "$BUILD" "$MC" "$ROOT/prefs"

echo "== source : $SRC"
echo "== outdir : $OUT"
echo "== binary : $BIN"

# ---- build ---------------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$SRC"/*.swift "$WORK"/

# Disable the SwiftUI App entry point *before* adding HarnessMain.swift, so we
# don't comment out the harness entry point as well.
for f in "$WORK"/*.swift; do
    /usr/bin/sed -i '' -E 's/^([[:space:]]*)@main([[:space:]]*)$/\1\/\/ @main (disabled by harness)\2/' "$f"
done
if grep -q '^@main' "$WORK"/*.swift; then
    echo "WARNING: an @main line survived sed; compilation may fail" >&2
fi
cp "$ROOT/templates/module.modulemap" "$ROOT/templates/shim.h" \
   "$ROOT/templates/HarnessMain.swift" "$WORK"/

t0=$(date +%s)
"$SWIFTC" -O -module-name P1Harness \
    -module-cache-path "$MC" \
    -I "$WORK" -I /opt/homebrew/include -Xcc -I/opt/homebrew/include \
    -L /opt/homebrew/lib -lusb-1.0 \
    -o "$BIN" "$WORK"/*.swift
echo "== built in $(( $(date +%s) - t0 )) s"

rm -rf "$OUT"
mkdir -p "$OUT"

# ---- probe + grab point --------------------------------------------------
echo
echo "== probe =="
"$BIN" --probe "$OUT"

echo
echo "== grab point (centre of the dark text on the paper) =="
"$PY" "$ROOT/probe_target.py" "$OUT" > "$OUT/target.json"
"$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("grab x=%.2f y=%.2f  scale=%.4f pt/dot  objects=%d" % (d["x"], d["y"], d["scale"], d["dark_objects"]))' "$OUT/target.json"

# ---- measured drag -------------------------------------------------------
echo
echo "== drag (20 x (+12,+6) pt, 30 ms settle per step) =="
"$BIN" --drag "$OUT/target.json" "$OUT"
"$PY" "$ROOT/analyze.py" "$OUT" | tee "$OUT/analysis_baseline.txt"

# ---- burst ---------------------------------------------------------------
if [ "$RUN_BURST" = "1" ]; then
    echo
    echo "== burst (20 drag events at 5 ms, snapshots) =="
    "$BIN" --burst "$OUT/target.json" "$OUT/burst"
    "$PY" "$ROOT/analyze.py" "$OUT/burst" | tee "$OUT/analysis_burst.txt"
fi

# ---- optional fine-step run (sub-dot oscillation) ------------------------
if [ "${HARNESS_FINE:-0}" = "1" ]; then
    echo
    echo "== fine-step drag (60 x (+2,+1) pt; sub-dot increments) =="
    HARNESS_STEPS=60 HARNESS_STEP_X=2 HARNESS_STEP_Y=1 \
        "$BIN" --drag "$OUT/target.json" "$OUT/fine"
    "$PY" "$ROOT/analyze.py" "$OUT/fine" | tee "$OUT/analysis_fine.txt"
fi

# ---- copy representative frames for inspection ---------------------------
cp "$OUT/frame_01.png" "$OUT/representative_frame_01.png" 2>/dev/null || true
cp "$OUT/frame_10.png" "$OUT/representative_frame_10.png" 2>/dev/null || true
cp "$OUT/frame_20.png" "$OUT/representative_frame_20.png" 2>/dev/null || true
cp "$OUT/frame_end.png" "$OUT/representative_frame_end.png" 2>/dev/null || true

# ---- summary -------------------------------------------------------------
echo
echo "================ SUMMARY ================"
"$PY" - "$OUT" <<'PYEOF'
import json, os, re, sys
out = sys.argv[1]
log = json.load(open(os.path.join(out, "drag_log.json")))
text = open(os.path.join(out, "analysis_baseline.txt")).read()
def grab(pat, default="?"):
    m = re.search(pat, text)
    return m.groups() if m else default
print("steps              : %d, drag elapsed %.2f s" % (len(log["steps"]), log["elapsed"]))
print("scale              : %s pt/dot" % (grab(r"canvas scale: ([0-9.]+) pt/dot")[0] if grab(r"canvas scale: ([0-9.]+) pt/dot") != "?" else "?"))
m = re.search(r"final cursor delta: \(([-0-9.]+), ([-0-9.]+)\) pt; observed element delta: \(([-0-9.]+), ([-0-9.]+)\) pt", text)
if m:
    print("final cursor delta : (%+.1f, %+.1f) pt" % (float(m.group(1)), float(m.group(2))))
    print("element delta      : (%+.1f, %+.1f) pt  -> %.2fx of cursor"
          % (float(m.group(3)), float(m.group(4)),
             float(m.group(3)) / float(m.group(1)) if float(m.group(1)) else 0.0))
m = re.search(r"tracking ratio .*: min ([0-9.]+) max ([0-9.]+) mean ([0-9.]+)", text)
if m:
    print("tracking ratio     : min %.2f max %.2f mean %.2f" % tuple(map(float, m.groups())))
m = re.search(r"max \|tracking error\| vs cursor: ([0-9.]+) pt ; vs dot grid: ([0-9.]+) pt ; max ghost residual: ([0-9]+) px", text)
if m:
    print("max tracking error : %.2f pt (cursor) / %.2f pt (dot grid)" % (float(m.group(1)), float(m.group(2))))
    print("max ghost residual : %s px" % m.group(3))
m = re.search(r"object count per frame: (.*)", text)
if m:
    print("objects per frame  : %s" % m.group(1))
m = re.search(r"observed dot shift: \(([-+0-9.]+), ([-+0-9.]+)\) dots; expected for 1:1 drag: \(([-+0-9.]+), ([-+0-9.]+)\) dots", text)
if m:
    print("dot shift          : observed (%s, %s) vs expected (%s, %s)"
          % tuple(m.groups()))
m = re.search(r"committed model position \(inferred\): (.*)", text)
if m:
    print("committed model    : %s" % m.group(1))
m = re.search(r"expected model position for 1:1 tracking: (.*)", text)
if m:
    print("expected model     : %s" % m.group(1))
print("representative pngs: frame_01/10/20/end + burst/ under %s" % out)
PYEOF

for f in "$OUT/analysis_baseline.txt" "$OUT/analysis_burst.txt" "$OUT/analysis_fine.txt"; do
    [ -f "$f" ] || continue
    echo "--- $f"
    grep -E "tracking ratio|max \|tracking error|object count per frame|ghost px per frame|final cursor delta|observed dot shift|committed model position|expected model position|box-delta minus|median \|box-text|NO text object" "$f" || true
done
echo "========================================="
echo "done.  probe/drag frames + analysis are in $OUT"
