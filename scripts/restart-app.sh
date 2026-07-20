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
# This script quits gracefully (never SIGKILL unless --force), waits for both the
# process to exit and the port to free, then relaunches.
#
# Channel selection:
#   (default)    dist/Banyan.app          — the freshly packaged candidate build
#   --stable     /Applications/Banyan.app — the promoted install (package-app.sh)
#   --previous   dist/Banyan-previous.app — the stable that the last promotion replaced
#   --force      escalate to SIGKILL if the running instance ignores quit/SIGTERM
#                (for rescuing from a hung dev build; may corrupt window-restoration
#                state, which the next launch survives at the cost of window layout)
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Banyan.app"
BUNDLE_ID="dev.banyudu.banyan"
PORT=7842
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --stable) APP="/Applications/Banyan.app" ;;
    --previous) APP="$ROOT_DIR/dist/Banyan-previous.app" ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "restart-app: unknown option '$arg' (--stable | --previous | --force)" >&2; exit 1 ;;
  esac
done

BIN="$APP/Contents/MacOS/Banyan"

if [[ ! -x "$BIN" ]]; then
  echo "restart-app: $BIN not found — run scripts/package-app.sh first." >&2
  exit 1
fi

# Any Banyan instance must be stopped before switching channels: they all share
# control port 7842 and state.sqlite. This covers the packaged apps and dev-watch's
# bare debug/release binaries.
INSTANCE_PATTERNS=(
  "$ROOT_DIR/dist/Banyan.app/Contents/MacOS/Banyan"
  "$ROOT_DIR/dist/Banyan-previous.app/Contents/MacOS/Banyan"
  "/Applications/Banyan.app/Contents/MacOS/Banyan"
  "$ROOT_DIR/.build/debug/Banyan"
  "$ROOT_DIR/.build/release/Banyan"
)

running() {
  local p
  for p in "${INSTANCE_PATTERNS[@]}"; do
    pgrep -f "$p" >/dev/null 2>&1 && return 0
  done
  return 1
}
signal_all() {
  local sig="$1" p
  for p in "${INSTANCE_PATTERNS[@]}"; do
    pkill "-$sig" -f "$p" >/dev/null 2>&1 || true
  done
}
port_busy() { lsof -nP -iTCP:"$PORT" >/dev/null 2>&1; }

if running; then
  echo "Quitting Banyan gracefully…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

  # Wait up to ~10s for a clean exit.
  for _ in $(seq 1 50); do running || break; sleep 0.2; done

  # Escalate to SIGTERM (still lets the app run its termination). SIGKILL corrupts
  # restorable window state and crashes the next launch, so it stays behind --force
  # for the "dev build is hung" rescue case.
  if running; then
    echo "Still running; sending SIGTERM…"
    signal_all TERM
    for _ in $(seq 1 25); do running || break; sleep 0.2; done
  fi

  if running; then
    if [[ "$FORCE" == 1 ]]; then
      echo "Still running; --force set, sending SIGKILL…"
      signal_all KILL
      for _ in $(seq 1 25); do running || break; sleep 0.2; done
      # SIGKILL can leave corrupt window-restoration state that crashes the next
      # launch inside NSWindow.restoreStateWithCoder — clear it so launch succeeds.
      rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" 2>/dev/null || true
    else
      echo "restart-app: Banyan did not exit; re-run with --force to SIGKILL it." >&2
      exit 1
    fi
  fi

  if running; then
    echo "restart-app: Banyan still running even after SIGKILL; giving up." >&2
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
