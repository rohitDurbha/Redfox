#!/bin/bash
# Downloads the static ffmpeg build that ships inside Redfox.app and verifies its checksum.
# The binary lands in vendor/ffmpeg, which is ignored by git.
#
# Builds come from https://ffmpeg.martin-riedl.de (static, Apple silicon, includes
# x264, x265, libvpx, Opus, LAME, Vorbis, WebP and AV1). To upgrade, change FFMPEG_BUILD
# to a newer folder name from that site.
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_BUILD="${FFMPEG_BUILD:-1789931890_9.0.2}"
BASE="https://ffmpeg.martin-riedl.de/download/macos/arm64/$FFMPEG_BUILD"
OUT="vendor/ffmpeg"
STAMP="vendor/ffmpeg.build"

if [ -x "$OUT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$FFMPEG_BUILD" ]; then
    echo "ffmpeg $FFMPEG_BUILD already present"
    exit 0
fi

echo "==> Downloading ffmpeg $FFMPEG_BUILD"
mkdir -p vendor
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$BASE/ffmpeg.zip" -o "$TMP/ffmpeg.zip"
curl -fsSL "$BASE/ffmpeg.zip.sha256" -o "$TMP/ffmpeg.zip.sha256"

EXPECTED="$(awk '{print $1}' "$TMP/ffmpeg.zip.sha256")"
ACTUAL="$(shasum -a 256 "$TMP/ffmpeg.zip" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "Checksum mismatch for ffmpeg.zip (expected $EXPECTED, got $ACTUAL)"
    exit 1
fi
echo "Checksum verified ($ACTUAL)"

unzip -q -o "$TMP/ffmpeg.zip" -d "$TMP/unzipped"
FOUND="$(find "$TMP/unzipped" -type f -name ffmpeg | head -1)"
[ -n "$FOUND" ] || { echo "ffmpeg binary not found in the zip"; exit 1; }
cp "$FOUND" "$OUT"
chmod +x "$OUT"
xattr -c "$OUT" 2>/dev/null || true
echo "$FFMPEG_BUILD" > "$STAMP"
"$OUT" -hide_banner -version | head -1
