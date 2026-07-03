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
  local path="$ARTIFACT_DIR/$name.png"
  activate_app
  if "$CTL" screenshot --output "$path" >/dev/null 2>&1 && [[ -s "$path" ]]; then
    echo "Captured $path"
  elif screencapture -x "$path"; then
    echo "Captured $path"
  else
    echo "screencapture failed for $name" >"$ARTIFACT_DIR/$name.capture-failed.txt"
    echo "Screen capture unavailable; wrote $ARTIFACT_DIR/$name.capture-failed.txt" >&2
  fi
}

verify_png() {
  local path="$1"
  local width
  local height
  width="$(sips -g pixelWidth "$path" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
  height="$(sips -g pixelHeight "$path" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
  if [[ -z "$width" || -z "$height" || "$width" -lt 600 || "$height" -lt 400 ]]; then
    echo "Invalid visual artifact: $path (${width:-unknown}x${height:-unknown})" >&2
    return 1
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
verify_png "$ARTIFACT_DIR/01-session-marked.png"

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
verify_png "$ARTIFACT_DIR/02-after-relaunch.png"

"$CTL" remove --id "$SESSION_ID" >/dev/null
if tmux -L banyan has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
  echo "Expected $TMUX_SESSION to be removed" >&2
  exit 1
fi

echo "Banyan UI validation passed. Artifacts: $ARTIFACT_DIR"
