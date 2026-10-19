#!/bin/bash
# Compiles Redfox and assembles build/Redfox.app.
# Usage:  scripts/build-app.sh [version]      e.g. scripts/build-app.sh 1.0.12
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
BUILD_NUMBER="${VERSION##*.}"
ARCH="$(uname -m)"

echo "==> Compiling Redfox $VERSION for $ARCH"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

APP="build/Redfox.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Redfox" "$APP/Contents/MacOS/Redfox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/Logo.png "$APP/Contents/Resources/"

echo "==> Signing (ad hoc)"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
