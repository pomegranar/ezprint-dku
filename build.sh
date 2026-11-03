#!/bin/bash
# Build "DKU ezPrint.app" and, with --dmg, package it. Needs only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
# SwiftUI macros live in Xcode, not the command line tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="build/DKU ezPrint.app"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/DKU ezPrint"
cp Info.plist "$APP/Contents/"
cp -R Resources/ppd Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
    STAGE=build/dmg
    mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "DKU ezPrint" -srcfolder "$STAGE" -ov -format UDZO "build/DKU-ezPrint.dmg"
    echo "built build/DKU-ezPrint.dmg"
fi
