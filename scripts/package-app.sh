#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Banyan.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DIST_DIR/bin"

cp "$ROOT_DIR/.build/release/Banyan" "$MACOS_DIR/Banyan"
cp "$ROOT_DIR/.build/release/banyanctl" "$DIST_DIR/bin/banyanctl"

SWIFTTERM_BUNDLE="$(find "$ROOT_DIR/.build" -path '*release*' -name '*SwiftTerm*.bundle' -type d | head -n 1 || true)"
if [[ -n "$SWIFTTERM_BUNDLE" ]]; then
  cp -R "$SWIFTTERM_BUNDLE" "$RESOURCES_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Banyan</string>
  <key>CFBundleIdentifier</key>
  <string>dev.banyudu.banyan</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Banyan</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/Banyan" "$DIST_DIR/bin/banyanctl"
codesign --force --sign - "$APP_DIR" >/dev/null

echo "Packaged $APP_DIR"
echo "Installed CLI at $DIST_DIR/bin/banyanctl"
