#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Banyan.app"
CTL="$ROOT_DIR/dist/bin/banyanctl"
ARTIFACT_DIR="${BANYAN_UI_ARTIFACT_DIR:-$ROOT_DIR/artifacts/ui-validation}"
SESSION_ID="ui-smoke-$(date +%Y%m%d%H%M%S)"
TMUX_SESSION="banyan-$SESSION_ID"
STARTED_APP=0
REPLACED_RUNNING_APP=0

mkdir -p "$ARTIFACT_DIR"

if [[ ! -d "$APP" || ! -x "$CTL" ]]; then
  "$ROOT_DIR/scripts/package-app.sh"
fi

cleanup() {
  "$CTL" remove --id "$SESSION_ID" >/dev/null 2>&1 || true
  tmux -L banyan kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
  if [[ "$STARTED_APP" == "1" && "${BANYAN_KEEP_OPEN:-0}" != "1" ]]; then
    osascript -e 'tell application "Banyan" to quit' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_control_server() {
  local attempt
  for attempt in {1..80}; do
    if "$CTL" list >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "Banyan control server did not become available" >&2
  return 1
}

activate_app() {
  osascript -e 'tell application "Banyan" to activate' >/dev/null
  sleep 0.8
}

capture() {
  local name="$1"
  activate_app
  if screencapture -x "$ARTIFACT_DIR/$name.png"; then
    echo "Captured $ARTIFACT_DIR/$name.png"
  else
    echo "screencapture failed for $name" >"$ARTIFACT_DIR/$name.capture-failed.txt"
    echo "Screen capture unavailable; wrote $ARTIFACT_DIR/$name.capture-failed.txt" >&2
  fi
}

wait_for_tmux_session() {
  local name="$1"
  local attempt
  for attempt in {1..40}; do
    if tmux -L banyan has-session -t "$name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "tmux session $name did not appear on socket banyan" >&2
  return 1
}

if pgrep -x Banyan >/dev/null 2>&1 && [[ "${BANYAN_REUSE_RUNNING:-0}" != "1" ]]; then
  osascript -e 'tell application "Banyan" to quit' >/dev/null 2>&1 || true
  REPLACED_RUNNING_APP=1
  for _ in {1..40}; do
    pgrep -x Banyan >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

if ! pgrep -x Banyan >/dev/null 2>&1; then
  open -n "$APP"
  STARTED_APP=1
fi

wait_for_control_server
activate_app

"$CTL" spawn \
  --id "$SESSION_ID" \
  --title "UI Smoke" \
  --cwd "$ROOT_DIR" \
  --cmd "printf 'Banyan UI smoke session ready\n'; exec \"${SHELL:-/bin/zsh}\" -l" >/dev/null

"$CTL" mark --id "$SESSION_ID" --status need-input --tone yellow --title "UI Smoke Needs Input" >/dev/null

wait_for_tmux_session "$TMUX_SESSION"
capture "01-session-marked"

osascript -e 'tell application "Banyan" to quit' >/dev/null
sleep 1

wait_for_tmux_session "$TMUX_SESSION"

open -n "$APP"
STARTED_APP=1
wait_for_control_server
activate_app

"$CTL" list | grep -q "$SESSION_ID"
wait_for_tmux_session "$TMUX_SESSION"
capture "02-after-relaunch"

"$CTL" remove --id "$SESSION_ID" >/dev/null
if tmux -L banyan has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
  echo "Expected $TMUX_SESSION to be removed" >&2
  exit 1
fi

echo "Banyan UI validation passed. Artifacts: $ARTIFACT_DIR"
