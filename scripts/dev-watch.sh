#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Banyan"
DEBUG_BIN="$ROOT_DIR/.build/debug/$APP_NAME"
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
  pkill -f "$DEBUG_BIN" >/dev/null 2>&1 || true
}

build_and_restart() {
  printf '\n[%s] Building debug Banyan...\n' "$(date '+%H:%M:%S')"
  if ! swift build; then
    printf '[%s] Build failed; keeping previous client state.\n' "$(date '+%H:%M:%S')"
    return
  fi

  cleanup
  stop_running_client

  printf '[%s] Launching %s\n' "$(date '+%H:%M:%S')" "$DEBUG_BIN"
  "$DEBUG_BIN" &
  PID="$!"
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
