#!/usr/bin/env bash
# Restart the packaged Banyan app cleanly.
#
# Why this exists: a naive kill+relaunch caused two failures we hit in practice —
#   1) relaunching before the old instance released control port 7842, so the new
#      listener never bound (now also mitigated by ControlServer bind-retry), and
#   2) SIGKILL (`kill -9`) leaving corrupt window-restoration state, which then
#      crashed the next launch inside AppKit's NSWindow.restoreStateWithCoder path
#      and left the app running windowless (so onAppear/the control server never ran).
#
# This script quits gracefully (never SIGKILL), waits for both the process to exit
# and the port to free, then relaunches.
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Banyan.app"
BIN="$APP/Contents/MacOS/Banyan"
BUNDLE_ID="dev.banyudu.banyan"
PORT=7842

if [[ ! -x "$BIN" ]]; then
  echo "restart-app: $BIN not found — run scripts/package-app.sh first." >&2
  exit 1
fi

running() { pgrep -f "$BIN" >/dev/null 2>&1; }
port_busy() { lsof -nP -iTCP:"$PORT" >/dev/null 2>&1; }

if running; then
  echo "Quitting Banyan gracefully…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

  # Wait up to ~10s for a clean exit.
  for _ in $(seq 1 50); do running || break; sleep 0.2; done

  # Escalate to SIGTERM (still lets the app run its termination) — never SIGKILL,
  # which corrupts restorable state and crashes the next launch.
  if running; then
    echo "Still running; sending SIGTERM…"
    pkill -TERM -f "$BIN" >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do running || break; sleep 0.2; done
  fi

  if running; then
    echo "restart-app: Banyan did not exit; aborting to avoid a forced kill." >&2
    exit 1
  fi
fi

# Wait for the control port to be released before relaunching.
for _ in $(seq 1 40); do port_busy || break; sleep 0.25; done
if port_busy; then
  echo "restart-app: port $PORT still in use after quit; relaunching anyway (bind-retry will recover)." >&2
fi

echo "Launching Banyan…"
open "$APP"

# Confirm the control server comes back up.
CTL="$ROOT_DIR/dist/bin/banyanctl"
if [[ -x "$CTL" ]]; then
  for i in $(seq 1 25); do
    if ! "$CTL" list >/dev/null 2>&1; then sleep 1; continue; fi
    echo "Control server is up (after ~${i}s)."
    exit 0
  done
  echo "restart-app: control server did not respond within 25s — check the app window." >&2
  exit 1
fi

echo "Restarted."
