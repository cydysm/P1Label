#!/bin/bash
# Build P1Label.app
# SPDX-License-Identifier: GPL-3.0-or-later
set -e
cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/P1Label.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>P1标签打印</string>
    <key>CFBundleDisplayName</key>       <string>P1标签打印</string>
    <key>CFBundleExecutable</key>        <string>P1Label</string>
    <key>CFBundleIdentifier</key>        <string>local.p1label</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>连接蓝牙标签打印机进行无线打印</string>
</dict>
</plist>
PLIST

swiftc -O \
    -module-name P1Label \
    -I "$ROOT/Sources" -I /opt/homebrew/include \
    -Xcc -I/opt/homebrew/include \
    -L /opt/homebrew/lib -lusb-1.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$APP/Contents/MacOS/P1Label" \
    Sources/LPAPI.swift Sources/P1USB.swift Sources/P1BLE.swift Sources/PaperSizes.swift Sources/LabelRenderer.swift Sources/LabelCanvas.swift Sources/P1LabelApp.swift

# Bundle libusb so the app is self-contained
cp /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib "$APP/Contents/Frameworks/"
install_name_tool -change /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib \
    @rpath/libusb-1.0.0.dylib "$APP/Contents/MacOS/P1Label"

codesign --force -s - "$APP"
echo "Built: $APP"
