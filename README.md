# Banyan

Banyan is a native macOS session cockpit for running many long-lived agent or terminal tasks without packing every session into a grid of panes.

The first screen is the working surface:

- left sidebar: sessions, status signals, tone, title, and compact session actions
- right side: the selected terminal session
- each session is backed by a persistent `tmux` session, so agents keep running across Banyan restarts
- programmatic control is available through `banyanctl`

The toolbar is intentionally small:

- `+` forks the selected session's working directory into a new default shell.
- `slider.horizontal.3` opens Preferences for terminal appearance.
- Sidebar options, including sort order and custom session creation, live behind the small sidebar menu.
- Restored sessions attach to existing `tmux` sessions when possible.

## Requirements

Banyan requires `tmux` for every terminal session:

```sh
brew install tmux
```

Banyan owns the native macOS UI; `tmux` owns the long-running shell or agent process. Closing Banyan or detaching a session only closes the tmux client in Banyan, not the underlying tmux session.

## Build

```sh
swift build
```

## Run

```sh
swift run Banyan
```

The app starts a local control server on `127.0.0.1:7842`.

Live terminal processes are kept by `tmux` using session names prefixed with `banyan-`.

Session metadata is saved to:

```text
~/Library/Application Support/Banyan/sessions.json
```

## Package

```sh
scripts/generate-icons.sh
scripts/package-app.sh
open dist/Banyan.app
```

The logo source lives at `Assets/BanyanLogo.svg`. The icon script generates `Assets/AppIcon.icns`, and the packaging script creates an ad-hoc signed `dist/Banyan.app` with that icon plus the companion CLI at `dist/bin/banyanctl`.

## Control From Scripts

Keep Banyan open, then drive it from another shell:

```sh
swift run banyanctl spawn \
  --id ENG-6685 \
  --title "ENG-6685" \
  --cwd /Users/banyudu/dev/2enai/clawly \
  --cmd "codex"

swift run banyanctl mark --id ENG-6685 --status need-input --tone yellow
swift run banyanctl mark --id ENG-6685 --status review --tone purple --title "ENG-6685 review"
swift run banyanctl close --id ENG-6685
swift run banyanctl respawn --id ENG-6685
swift run banyanctl remove --id ENG-6685
swift run banyanctl list
```

`close` detaches and hides the Banyan view while leaving the tmux session alive. `respawn` reattaches to an existing tmux session or recreates it from the saved command if it no longer exists. `remove` is destructive and kills the backing tmux session.

The control API uses a versioned JSON schema (`apiVersion: "v1"`) and a local shared token stored at:

```text
~/Library/Application Support/Banyan/control-token
```

`banyanctl` sends this token automatically with `X-Banyan-Token`.

Supported statuses:

```text
running
need-input
review
completed
failed
closed
```

Supported tones:

```text
neutral
blue
green
yellow
red
purple
```

## Terminal Rendering

Banyan embeds SwiftTerm, so terminal applications can use ANSI, 256-color, and truecolor escape sequences for syntax highlighting and colorized output. Banyan exposes theme and font controls in Preferences.

Built-in themes:

- System
- Dark
- Light
- Solarized Dark
- Solarized Light
- Dracula

## Agent State Detection

Banyan watches terminal output for common agent states and can mark sessions as `need-input`, `review`, `failed`, or `completed`. It sends macOS notifications for attention states.

Global detector rules can be overridden with:

```text
~/Library/Application Support/Banyan/detectors.json
```

Example:

```json
[
  {
    "status": "need-input",
    "tone": "yellow",
    "patterns": ["waiting for approval", "permission required"]
  }
]
```

## Current Scope

This repo starts as a Swift Package executable for fast native iteration. The local package script creates an ad-hoc signed `.app`; distribution signing/notarization can be added later if needed.
