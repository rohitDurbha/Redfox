#!/bin/bash
# Wraps build/Redfox.app in a drag-to-install disk image at build/Redfox.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Redfox.app"
DMG="build/Redfox.dmg"
STAGE="build/dmg"
[ -d "$APP" ] || { echo "Run scripts/build-app.sh first."; exit 1; }

echo "==> Creating $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$STAGE" || true; fi

hdiutil create -volname "Redfox" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
rm -rf "$STAGE"
echo "Built $DMG"
