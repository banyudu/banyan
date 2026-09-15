#!/usr/bin/env bash
# Restart the packaged Banyan app cleanly.
#
# Why this exists: a naive kill+relaunch caused three failures we hit in practice —
#   1) relaunching before the old instance released control port 7842, so the new
#      listener never bound (now also mitigated by ControlServer bind-retry),
#   2) SIGKILL (`kill -9`) leaving incomplete window-restoration state, which then
#      crashed the next launch inside AppKit's NSWindow.restoreStateWithCoder path
#      and left the app running windowless (so onAppear/the control server never ran).
#      Banyan disables AppKit's image snapshots, but retains ordinary restoration,
#      so the forced-restart cleanup remains a precaution, and
#   3) looking for running instances only under this script's own checkout, so an
#      app launched from another one was invisible: the quit step was skipped and
#      a second instance launched against the same port and the same state.sqlite.
#
# This script quits gracefully (never SIGKILL unless --force), waits for both the
# process to exit and the port to free, then relaunches. It refuses to launch
# while another Banyan still owns the port.
#
# Which checkout:
#   By default this acts on the MAIN checkout, not on the worktree the script
#   happens to live in — after merging, the intent is normally "run what is on
#   main". Pass --here for this script's own checkout, or set BANYAN_ROOT to pin
#   one explicitly.
#
# Channel selection:
#   (default)    <root>/dist/Banyan.app          — the freshly packaged candidate build
#   --stable     /Applications/Banyan.app        — the promoted install (package-app.sh)
#   --previous   <root>/dist/Banyan-previous.app — the stable that the last promotion replaced
#   --here       treat this script's checkout as <root> instead of the main one
#   --force      escalate to SIGKILL if the running instance ignores quit/SIGTERM
#                (for rescuing from a hung dev build; may corrupt window-restoration
#                state, which the next launch survives at the cost of window layout)
set -euo pipefail

SCRIPT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/repo-root.sh
source "$SCRIPT_ROOT/scripts/lib/repo-root.sh"

BUNDLE_ID="dev.banyudu.banyan"
PORT=7842
FORCE=0
HERE=0
CHANNEL=candidate

for arg in "$@"; do
  case "$arg" in
    --stable) CHANNEL=stable ;;
    --previous) CHANNEL=previous ;;
    --here) HERE=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "restart-app: unknown option '$arg' (--stable | --previous | --here | --force)" >&2; exit 1 ;;
  esac
done

ROOT_DIR="$(banyan_resolve_root "$SCRIPT_ROOT" "$HERE")"
banyan_announce_root "$ROOT_DIR" "$SCRIPT_ROOT" "Using checkout:"

case "$CHANNEL" in
  stable) APP="/Applications/Banyan.app" ;;
  previous) APP="$ROOT_DIR/dist/Banyan-previous.app" ;;
  *) APP="$ROOT_DIR/dist/Banyan.app" ;;
esac

BIN="$APP/Contents/MacOS/Banyan"

if [[ ! -x "$BIN" ]]; then
  echo "restart-app: $BIN not found — run scripts/package-app.sh first." >&2
  exit 1
fi

# Any Banyan instance must be stopped before switching channels: they all share
# control port 7842 and state.sqlite. These paths cover the channels of the
# checkouts in play (the resolved one, this script's own, and the promoted
# install) plus dev-watch's bare debug/release binaries.
INSTANCE_PATTERNS=(
  "/Applications/Banyan.app/Contents/MacOS/Banyan"
  "$ROOT_DIR/dist/Banyan.app/Contents/MacOS/Banyan"
  "$ROOT_DIR/dist/Banyan-previous.app/Contents/MacOS/Banyan"
  "$ROOT_DIR/.build/debug/Banyan"
  "$ROOT_DIR/.build/release/Banyan"
)
if [[ "$SCRIPT_ROOT" != "$ROOT_DIR" ]]; then
  INSTANCE_PATTERNS+=(
    "$SCRIPT_ROOT/dist/Banyan.app/Contents/MacOS/Banyan"
    "$SCRIPT_ROOT/dist/Banyan-previous.app/Contents/MacOS/Banyan"
    "$SCRIPT_ROOT/.build/debug/Banyan"
    "$SCRIPT_ROOT/.build/release/Banyan"
  )
fi

# A path list can only cover the checkouts it knows about, and this repo has a
# worktree per issue. Whoever holds the control port is the instance that
# actually conflicts, so find it by PID too — no matter where it was launched.
port_banyan_pids() {
  local pid comm
  for pid in $(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true); do
    comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    [[ "$(basename "$comm")" == "Banyan" ]] && echo "$pid"
  done
}

running() {
  local p
  for p in "${INSTANCE_PATTERNS[@]}"; do
    pgrep -f "$p" >/dev/null 2>&1 && return 0
  done
  [[ -n "$(port_banyan_pids)" ]] && return 0
  return 1
}
signal_all() {
  local sig="$1" p pid
  for p in "${INSTANCE_PATTERNS[@]}"; do
    pkill "-$sig" -f "$p" >/dev/null 2>&1 || true
  done
  for pid in $(port_banyan_pids); do
    kill "-$sig" "$pid" >/dev/null 2>&1 || true
  done
}
port_busy() { lsof -nP -iTCP:"$PORT" >/dev/null 2>&1; }

if running; then
  echo "Quitting Banyan gracefully…"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

  # Wait up to ~10s for a clean exit.
  for _ in $(seq 1 50); do running || break; sleep 0.2; done

  # Escalate to SIGTERM (still lets the app run its termination). SIGKILL can leave
  # restorable state incomplete and crash the next launch, so it stays behind
  # --force for the "dev build is hung" rescue case.
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
      # A forced kill can leave incomplete restoration state that crashes the next
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
  STRAY_PIDS="$(port_banyan_pids)"
  if [[ -n "$STRAY_PIDS" ]]; then
    # Launching here is what produced two apps sharing one port and one database.
    echo "restart-app: another Banyan already owns port $PORT:" >&2
    for pid in $STRAY_PIDS; do
      echo "  pid $pid  $(ps -p "$pid" -o comm= 2>/dev/null)" >&2
    done
    echo "Quit it (or re-run with --force) before relaunching." >&2
    exit 1
  fi
  echo "restart-app: port $PORT held by a non-Banyan process; relaunching anyway (bind-retry will recover)." >&2
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
