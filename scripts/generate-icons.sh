#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT_DIR/Assets/BanyanLogo.svg"
ICONSET="$ROOT_DIR/Assets/AppIcon.iconset"
ICNS="$ROOT_DIR/Assets/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is required. Install it with: brew install librsvg" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

rsvg-convert -w 16 -h 16 "$SVG" -o "$ICONSET/icon_16x16.png"
rsvg-convert -w 32 -h 32 "$SVG" -o "$ICONSET/icon_16x16@2x.png"
rsvg-convert -w 32 -h 32 "$SVG" -o "$ICONSET/icon_32x32.png"
rsvg-convert -w 64 -h 64 "$SVG" -o "$ICONSET/icon_32x32@2x.png"
rsvg-convert -w 128 -h 128 "$SVG" -o "$ICONSET/icon_128x128.png"
rsvg-convert -w 256 -h 256 "$SVG" -o "$ICONSET/icon_128x128@2x.png"
rsvg-convert -w 256 -h 256 "$SVG" -o "$ICONSET/icon_256x256.png"
rsvg-convert -w 512 -h 512 "$SVG" -o "$ICONSET/icon_256x256@2x.png"
rsvg-convert -w 512 -h 512 "$SVG" -o "$ICONSET/icon_512x512.png"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"

echo "Generated $ICNS"
