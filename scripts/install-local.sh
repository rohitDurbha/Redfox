#!/bin/bash
# Optional. Builds Redfox on this Mac and installs it straight into /Applications.
# Most of the time you do not need this, because GitHub builds a DMG on every push.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v swift >/dev/null 2>&1 || { echo "Swift is missing. Run  xcode-select --install  first."; exit 1; }
scripts/build-app.sh "${1:-0.0.0}"

pkill -x Redfox 2>/dev/null || true
rm -rf /Applications/Redfox.app
cp -R build/Redfox.app /Applications/
touch /Applications/Redfox.app
open /Applications/Redfox.app
echo "Installed. Look for the fox in your menu bar."
