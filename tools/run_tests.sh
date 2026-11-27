#!/bin/bash
# Compile and run standalone unit tests for pure-Swift P1Label modules.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/p1label-tests"
swiftc -Onone \
    -target "$(uname -m)-apple-macosx13.0" \
    -o "$BIN" \
    "$ROOT/P1Label/Sources/LPAPI.swift" \
    "$ROOT/P1Label/Sources/PaperSizes.swift" \
    "$ROOT/P1Label/Sources/History.swift" \
    "$ROOT/P1Label/Sources/LabelRenderer.swift" \
    "$ROOT/P1Label/Sources/CanvasResize.swift" \
    "$ROOT/tools/tests/UnitTests.swift"

"$BIN"
