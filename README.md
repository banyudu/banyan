# Banyan

Banyan is a native macOS session cockpit for running many long-lived agent or terminal tasks without packing every session into a grid of panes.

The first screen is the working surface:

- left sidebar: sessions, status signals, tone, title, and compact session actions
- right side: the selected terminal session
- each session owns its own PTY-backed terminal, working directory, and command
- programmatic control is available through `banyanctl`

The toolbar is intentionally small:

- `+` forks the selected session's working directory into a new default shell.
- `slider.horizontal.3` opens Preferences for terminal appearance.
- Sidebar options, including sort order and custom session creation, live behind the small sidebar menu.

## Build

```sh
swift build
```

## Run

```sh
swift run Banyan
```

The app starts a local control server on `127.0.0.1:7842`.

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
swift run banyanctl remove --id ENG-6685
swift run banyanctl list
```

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

Banyan embeds SwiftTerm, so terminal applications can use ANSI, 256-color, and truecolor escape sequences for syntax highlighting and colorized output. Banyan currently exposes three terminal color sets:

- System
- Dark
- Light

## Current Scope

This repo starts as a Swift Package executable for fast native iteration. Packaging as a signed `.app`, durable session restore, richer terminal themes, notifications, and a hardened local control protocol are tracked as follow-up work.
