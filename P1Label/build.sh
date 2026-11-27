#!/bin/bash
# Build P1Label.app
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/P1Label.app"
MIN_MACOS="13.0"
ARCH="$(uname -m)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Resolve libusb dynamically (supports Apple Silicon /opt/homebrew, Intel /usr/local, custom prefixes).
if command -v brew >/dev/null && brew --prefix libusb >/dev/null 2>&1; then
    LIBUSB_PREFIX="$(brew --prefix libusb)"
elif [ -d /opt/homebrew/opt/libusb ]; then
    LIBUSB_PREFIX="/opt/homebrew/opt/libusb"
elif [ -d /usr/local/opt/libusb ]; then
    LIBUSB_PREFIX="/usr/local/opt/libusb"
else
    echo "error: libusb not found (install via 'brew install libusb')" >&2
    exit 1
fi
LIBUSB_INC="$LIBUSB_PREFIX/include"
LIBUSB_LIB="$LIBUSB_PREFIX/lib"
LIBUSB_DYLIB="$LIBUSB_LIB/libusb-1.0.0.dylib"
if [ ! -f "$LIBUSB_DYLIB" ]; then
    echo "error: $LIBUSB_DYLIB not found" >&2
    exit 1
fi

# Compile into temp binary first so a failed build does not wipe a working .app.
BIN_TMP="$TMP/P1Label"
swiftc -O \
    -target "${ARCH}-apple-macosx${MIN_MACOS}" \
    -module-name P1Label \
    -I "$ROOT/Sources" -I "$LIBUSB_INC" \
    -Xcc "-I$LIBUSB_INC" \
    -L "$LIBUSB_LIB" -lusb-1.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$BIN_TMP" \
    Sources/LPAPI.swift Sources/P1USB.swift Sources/P1BLE.swift Sources/PaperSizes.swift Sources/LabelRenderer.swift Sources/CanvasResize.swift Sources/DesignSystem.swift Sources/History.swift Sources/LabelCanvas.swift Sources/Inspector.swift Sources/MainWindow.swift Sources/P1LabelApp.swift

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
mv -f "$BIN_TMP" "$APP/Contents/MacOS/P1Label"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>P1标签打印</string>
    <key>CFBundleDisplayName</key>       <string>P1标签打印</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleExecutable</key>        <string>P1Label</string>
    <key>CFBundleIdentifier</key>        <string>local.p1label</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSRequiresAquaSystemAppearance</key> <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>连接蓝牙标签打印机进行无线打印</string>
</dict>
</plist>
PLIST

# Bundle libusb (dynamically linked per LGPL/GPL) so the app is self-contained.
LIBUSB_OLD_ID="$(otool -D "$LIBUSB_DYLIB" | tail -n 1)"
BUNDLED_DYLIB="$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cp -f "$LIBUSB_DYLIB" "$BUNDLED_DYLIB"
chmod u+w "$BUNDLED_DYLIB"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$BUNDLED_DYLIB"
install_name_tool -change "$LIBUSB_OLD_ID" @rpath/libusb-1.0.0.dylib "$APP/Contents/MacOS/P1Label"
codesign --force -s - "$BUNDLED_DYLIB"

# App icon: render Resources/icon.svg -> icns. Uses CoreSVG via AppKit for a
# transparent background (qlmanage thumbnails would flatten the rounded plate
# onto an opaque white square). Regenerated only when icon.svg changes.
ICON_SRC="$ROOT/Resources/icon.svg"
ICON_OUT="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null && command -v swift >/dev/null \
   && { [ ! -f "$ICON_OUT" ] || [ "$ICON_SRC" -nt "$ICON_OUT" ]; }; then
    if swift "$ROOT/Resources/render_icon.swift" "$ICON_SRC" "$TMP/icon1024.png"; then
        ICONSET="$TMP/AppIcon.iconset"
        mkdir -p "$ICONSET"
        while read -r sz name; do
            sips -z "$sz" "$sz" "$TMP/icon1024.png" --out "$ICONSET/$name.png" >/dev/null
        done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES
        iconutil -c icns "$ICONSET" -o "$ICON_OUT"
    else
        echo "warning: icon render failed, building without app icon" >&2
    fi
fi

codesign --force -s - "$APP"
echo "Built: $APP"
