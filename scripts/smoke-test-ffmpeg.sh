#!/bin/bash
# Uses the ffmpeg bundled inside build/Redfox.app to run every conversion that Redfox
# hands to ffmpeg, so a release never ships with a missing encoder.
set -euo pipefail
cd "$(dirname "$0")/.."

FF="build/Redfox.app/Contents/MacOS/ffmpeg"
[ -x "$FF" ] || { echo "Bundled ffmpeg is missing from the app"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
run() { "$FF" -y -hide_banner -loglevel error "$@"; }

# Sample inputs made by ffmpeg itself
run -f lavfi -i testsrc=size=320x240:rate=24:duration=2 -f lavfi -i sine=frequency=440:duration=2 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/in.mp4"
run -f lavfi -i testsrc=size=320x240 -frames:v 1 "$T/in.png"

check() {
    local name="$1"; shift
    if run "$@" && [ -s "${@: -1}" ]; then
        echo "  ok    $name"
    else
        echo "  FAIL  $name"
        FAILED=1
    fi
}

FAILED=0
echo "==> Testing bundled ffmpeg encoders"
check "mp4 (x264)"   -i "$T/in.mp4" -c:v libx264 -preset medium -crf 22 -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart "$T/out.mp4"
check "mkv"          -i "$T/in.mp4" -c copy "$T/out.mkv"
check "webm (vp9)"   -i "$T/in.mp4" -c:v libvpx-vp9 -crf 32 -b:v 0 -row-mt 1 -c:a libopus -b:a 128k "$T/out.webm"
check "avi"          -i "$T/in.mp4" -c:v mpeg4 -q:v 3 -c:a libmp3lame -q:a 3 "$T/out.avi"
check "gif"          -i "$T/in.mp4" -vf "fps=12,scale=320:-1:flags=lanczos" -loop 0 "$T/out.gif"
check "mp3"          -i "$T/in.mp4" -vn -c:a libmp3lame -q:a 2 "$T/out.mp3"
check "flac"         -i "$T/in.mp4" -vn -c:a flac "$T/out.flac"
check "ogg (vorbis)" -i "$T/in.mp4" -vn -c:a libvorbis -q:a 5 "$T/out.ogg"
check "opus"         -i "$T/in.mp4" -vn -c:a libopus -b:a 128k "$T/out.opus"
check "webp"         -i "$T/in.png" -c:v libwebp -quality 85 "$T/out.webp"
check "avif (aom)"   -i "$T/in.png" -c:v libaom-av1 -still-picture 1 -crf 30 -cpu-used 6 "$T/out.avif"

if [ "$FAILED" -ne 0 ]; then
    echo "One or more encoders failed."
    exit 1
fi
echo "All bundled encoders work."
