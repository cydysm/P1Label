#!/bin/bash
# Package P1Label.app into a distributable macOS DMG image.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:
#   ./P1Label/package_dmg.sh              # rebuild app and create dist/P1Label-<version>.dmg
#   ./P1Label/package_dmg.sh --no-build   # package existing P1Label.app without rebuilding
#   ./P1Label/package_dmg.sh 1.2.0        # override output version tag
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/P1Label.app"
DIST="$ROOT/dist"

DO_BUILD=1
VERSION_OVERRIDE=""
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            VERSION_OVERRIDE="$arg"
            ;;
    esac
done

if [ "$DO_BUILD" -eq 1 ]; then
    "$ROOT/build.sh"
fi

if [ ! -d "$APP" ]; then
    echo "error: $APP not found (run ./P1Label/build.sh first)" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP"

VERSION="${VERSION_OVERRIDE:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
mkdir -p "$DIST"
OUT="$DIST/P1Label-${VERSION}.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/P1Label.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create \
    -volname "P1Label ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$OUT"

echo ""
echo "Packaged: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
shasum -a 256 "$OUT"
