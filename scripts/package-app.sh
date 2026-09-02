#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/Banyan.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_FILE="$ROOT_DIR/Assets/AppIcon.icns"
INSTALL_DIR="${BANYAN_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/Banyan.app"
APP_VERSION="${BANYAN_VERSION:-0.2.8}"

cd "$ROOT_DIR"
rm -rf "$ROOT_DIR/.build/arm64-apple-macosx/release/ModuleCache"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DIST_DIR/bin"

cp "$ROOT_DIR/.build/release/Banyan" "$MACOS_DIR/Banyan"
cp "$ROOT_DIR/.build/release/banyanctl" "$DIST_DIR/bin/banyanctl"
if [[ ! -f "$ICON_FILE" ]]; then
  "$ROOT_DIR/scripts/generate-icons.sh"
fi
cp "$ICON_FILE" "$RESOURCES_DIR/Banyan.icns"

SWIFTTERM_BUNDLE="$(find "$ROOT_DIR/.build" -path '*release*' -name '*SwiftTerm*.bundle' -type d | head -n 1 || true)"
if [[ -n "$SWIFTTERM_BUNDLE" ]]; then
  cp -R "$SWIFTTERM_BUNDLE" "$RESOURCES_DIR/"
fi
BANYAN_RESOURCE_BUNDLE="$(find "$ROOT_DIR/.build" -path '*release*' -name 'Banyan_Banyan.bundle' -type d | head -n 1 || true)"
if [[ -n "$BANYAN_RESOURCE_BUNDLE" ]]; then
  cp -R "$BANYAN_RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

# Stamp the build so About/Info.plist identifies which commit a stable install is.
GIT_BUILD="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT_DIR" diff --quiet HEAD 2>/dev/null; then
  GIT_BUILD="$GIT_BUILD-dirty"
fi
GIT_BUILD="$GIT_BUILD ($(date '+%Y-%m-%d %H:%M'))"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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
  <key>CFBundleIconFile</key>
  <string>Banyan</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${GIT_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$MACOS_DIR/Banyan" "$DIST_DIR/bin/banyanctl"

# Sign with a stable identity so macOS keeps granted permissions across rebuilds.
# An ad-hoc signature's designated requirement is a bare cdhash, which changes on
# every build — even from identical source — so TCC treats each build as a new app
# and drops its grants. A Developer ID requirement keys on bundle id + team id
# instead, which is stable.
#
# Deliberately not $APPLE_SIGNING_IDENTITY: that holds an "Apple Distribution"
# identity for App Store submission, which needs a provisioning profile to launch.
SIGNING_IDENTITY="${BANYAN_SIGNING_IDENTITY:-${APPLE_SIGNING_IDENTITY_DEV:-}}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
fi
if [[ -n "$SIGNING_IDENTITY" ]] && codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null 2>&1; then
  echo "Signed with: $SIGNING_IDENTITY"
else
  # No certificate configured or available: still produce a working local build.
  codesign --force --sign - "$APP_DIR" >/dev/null
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "WARNING: set APPLE_SIGNING_IDENTITY_DEV (or BANYAN_SIGNING_IDENTITY) to a"
    echo "         'Developer ID Application' identity — signed ad-hoc instead."
  else
    echo "WARNING: '$SIGNING_IDENTITY' unavailable — signed ad-hoc instead."
  fi
  echo "         The app still runs, but macOS will reset its permissions on each rebuild."
fi

echo "Packaged $APP_DIR"
echo "Installed CLI at $DIST_DIR/bin/banyanctl"

# Install into /Applications so the app you launch from Spotlight/Dock is the one
# just built. Set BANYAN_INSTALL_DIR to redirect, or BANYAN_SKIP_INSTALL=1 to skip.
if [[ "${BANYAN_SKIP_INSTALL:-0}" == "1" ]]; then
  echo "Skipped install (BANYAN_SKIP_INSTALL=1)"
  exit 0
fi

# A running instance keeps its old image alive on a deleted inode, so replacing the
# bundle underneath it is safe but leaves that process on stale code until relaunch.
app_was_running=0
if pgrep -f "$INSTALLED_APP/Contents/MacOS/Banyan" >/dev/null 2>&1; then
  app_was_running=1
fi

# Keep the outgoing stable install as a rollback target for restart-app.sh --previous.
if [[ -d "$INSTALLED_APP" ]]; then
  rm -rf "$DIST_DIR/Banyan-previous.app"
  cp -R "$INSTALLED_APP" "$DIST_DIR/Banyan-previous.app"
  echo "Archived previous install to $DIST_DIR/Banyan-previous.app"
fi

rm -rf "$INSTALLED_APP"
cp -R "$APP_DIR" "$INSTALLED_APP"
# cp preserves the ad-hoc signature (it covers bundle contents, not path), so verify
# rather than re-sign — a failure here means the copy, not the signing, went wrong.
codesign --verify --deep "$INSTALLED_APP"

echo "Installed $INSTALLED_APP"
if [[ "$app_was_running" == "1" ]]; then
  echo "NOTE: Banyan is running from an older build — quit and relaunch to pick this up."
fi
