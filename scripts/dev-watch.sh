#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Banyan"
DEBUG_BIN="$ROOT_DIR/.build/debug/$APP_NAME"
DEV_APP="$ROOT_DIR/.build/dev/Banyan.app"
PID=""

cd "$ROOT_DIR"

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
    wait "$PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

fingerprint() {
  {
    find Sources Tests -type f -name '*.swift' -print
    printf '%s\n' Package.swift Package.resolved
  } | sort | while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    stat -f '%m %z %N' "$file"
  done | shasum
}

stop_running_client() {
  osascript -e 'tell application id "dev.banyudu.banyan" to quit' >/dev/null 2>&1 || true
  pkill -f "$ROOT_DIR/dist/Banyan.app/Contents/MacOS/Banyan" >/dev/null 2>&1 || true
  pkill -f "$DEV_APP/Contents/MacOS/Banyan" >/dev/null 2>&1 || true
  pkill -f "$DEBUG_BIN" >/dev/null 2>&1 || true
}

package_dev_app() {
  local contents="$DEV_APP/Contents"
  local macos="$contents/MacOS"
  local resources="$contents/Resources"

  mkdir -p "$macos" "$resources"
  cp "$DEBUG_BIN" "$macos/Banyan"
  find "$ROOT_DIR/.build" -path '*debug*' -name '*.bundle' -type d -exec cp -R {} "$resources/" \;

  cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Banyan</string>
  <key>CFBundleIdentifier</key><string>dev.banyudu.banyan</string>
  <key>CFBundleName</key><string>Banyan</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>dev</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  chmod +x "$macos/Banyan"

  local identity="${BANYAN_SIGNING_IDENTITY:-${APPLE_SIGNING_IDENTITY_DEV:-}}"
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
  fi
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
  fi

  if [[ -n "$identity" ]] && codesign --force --sign "$identity" "$DEV_APP" >/dev/null 2>&1; then
    printf '[%s] Signed dev app with: %s\n' "$(date '+%H:%M:%S')" "$identity"
  else
    codesign --force --sign - "$DEV_APP" >/dev/null
    printf '[%s] WARNING: no stable signing identity; TCC permissions may reset.\n' "$(date '+%H:%M:%S')"
  fi
}

build_and_restart() {
  printf '\n[%s] Building debug Banyan...\n' "$(date '+%H:%M:%S')"
  if ! swift build; then
    printf '[%s] Build failed; keeping previous client state.\n' "$(date '+%H:%M:%S')"
    return
  fi

  package_dev_app

  cleanup
  stop_running_client

  printf '[%s] Launching %s\n' "$(date '+%H:%M:%S')" "$DEV_APP"
  open --new "$DEV_APP"
  PID=""
}

last_fingerprint=""
build_and_restart
last_fingerprint="$(fingerprint)"

printf '\nWatching Sources/, Tests/, Package.swift, and Package.resolved.\n'
printf 'Press Ctrl-C to stop. Tmux sessions are not killed by this script.\n'

while true; do
  sleep 1
  current_fingerprint="$(fingerprint)"
  if [[ "$current_fingerprint" != "$last_fingerprint" ]]; then
    last_fingerprint="$current_fingerprint"
    build_and_restart
  fi
done
