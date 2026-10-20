#!/usr/bin/env bash
# Launch an isolated Banyan instance for energy investigations.
#
# The lab instance gets its own data directory, control port, tmux socket, and
# copied app bundle. It therefore cannot touch the production sessions or the
# production SQLite database, and scripts/restart-app.sh does not target it.
#
# Usage:
#   scripts/lab-app.sh [--package] [--reset] [--here]
#
# The app bundle defaults to <root>/dist/Banyan.app. --package builds it first
# without promoting it to /Applications.
set -euo pipefail

SCRIPT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/repo-root.sh
source "$SCRIPT_ROOT/scripts/lib/repo-root.sh"

PACKAGE=0
HERE=0
RESET=0
for arg in "$@"; do
  case "$arg" in
    --package) PACKAGE=1 ;;
    --reset) RESET=1 ;;
    --here) HERE=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "lab-app: unknown option '$arg' (--package | --reset | --here)" >&2; exit 1 ;;
  esac
done

ROOT_DIR="$(banyan_resolve_root "$SCRIPT_ROOT" "$HERE")"
banyan_announce_root "$ROOT_DIR" "$SCRIPT_ROOT" "Using checkout:"

APP="${BANYAN_LAB_APP:-$ROOT_DIR/dist/Banyan.app}"
LAB_HOME="${BANYAN_LAB_HOME:-/tmp/banyan-lab}"
PORT="${BANYAN_LAB_PORT:-7843}"
SOCKET="${BANYAN_LAB_TMUX_SOCKET:-banyan-lab-$PORT}"
LAB_APP="$LAB_HOME/Banyan.app"
DATA_HOME="$LAB_HOME/data"
LAB_PATTERN="banyan-lab/Banyan.app/Contents/MacOS/Banyan"

if [[ "$PACKAGE" == 1 ]]; then
  BANYAN_SKIP_INSTALL=1 "$ROOT_DIR/scripts/package-app.sh" --here
fi

if [[ ! -x "$APP/Contents/MacOS/Banyan" ]]; then
  echo "lab-app: $APP not found; run scripts/package-app.sh --here first" >&2
  exit 1
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "lab-app: invalid BANYAN_LAB_PORT '$PORT'" >&2
  exit 1
fi
mkdir -p "$DATA_HOME" "$LAB_HOME"
if pgrep -f "$LAB_PATTERN" >/dev/null 2>&1; then
  echo "lab-app: stopping previous lab instance" >&2
  pkill -TERM -f "$LAB_PATTERN" 2>/dev/null || true
  for _ in {1..50}; do pgrep -f "$LAB_PATTERN" >/dev/null 2>&1 || break; sleep 0.1; done
  for _ in {1..50}; do
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "lab-app: port $PORT is already in use" >&2
  exit 1
fi

if [[ "$RESET" == 1 ]]; then
  echo "lab-app: resetting $LAB_HOME" >&2
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB_HOME"
  mkdir -p "$DATA_HOME" "$LAB_HOME"
fi

rm -rf "$LAB_APP"
ditto "$APP" "$LAB_APP"

cat > "$LAB_HOME/env.sh" <<EOF_ENV
export BANYAN_FIXTURE_DATA_HOME="$DATA_HOME"
export BANYAN_FIXTURE_CONTROL_URL="http://127.0.0.1:$PORT"
export BANYAN_TMUX_SOCKET="$SOCKET"
export BANYAN_CONTROL_PORT="$PORT"
EOF_ENV

open -n -g \
  --env BANYAN_FIXTURE_DATA_HOME="$DATA_HOME" \
  --env BANYAN_FIXTURE_CONTROL_URL="http://127.0.0.1:$PORT" \
  --env BANYAN_TMUX_SOCKET="$SOCKET" \
  --env BANYAN_CONTROL_PORT="$PORT" \
  --env BANYAN_LAB=1 \
  --env BANYAN_CPU_CAPTURE=0 \
  --env BANYAN_ENERGY_TRACE=1 \
  --env BANYAN_TERMINAL_DIAGNOSTICS=1 \
  "$LAB_APP" --args -ApplePersistenceIgnoreState YES

sleep 0.5
pgrep -f "$LAB_PATTERN" | head -1 > "$LAB_HOME/app.pid" || true

for _ in {1..100}; do
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "lab-app: control server did not bind port $PORT" >&2
  exit 1
fi

echo "lab home:  $LAB_HOME"
echo "app:       $LAB_APP"
echo "control:   http://127.0.0.1:$PORT"
echo "tmux:      $SOCKET"
echo "trace log: log stream --predicate 'subsystem == \"dev.banyudu.banyan\" AND category == \"energy-trace\"' --info"
echo "use it:    source $LAB_HOME/env.sh"
