# Banyan

Banyan is a native macOS session cockpit for running many long-lived agent or terminal tasks without packing every session into a grid of panes.

The first screen is the working surface:

- left sidebar: sessions, status signals, tone, title, and compact session actions
- right side: the selected terminal session
- each session is backed by a persistent `tmux` session, so agents keep running across Banyan restarts
- programmatic control is available through `banyanctl`

The toolbar is intentionally small:

- `+` forks the selected session's working directory into a new default shell.
- `slider.horizontal.3` opens Preferences for app theme and terminal font.
- Sidebar options, including sort order and custom session creation, live behind the small sidebar menu.
- Restored sessions attach to existing `tmux` sessions when possible.

## Requirements

Banyan requires `tmux` for every terminal session:

```sh
brew install tmux
```

Banyan owns the native macOS UI; `tmux` owns the long-running shell or agent process. Closing Banyan or detaching a session only closes the tmux client in Banyan, not the underlying tmux session.

Banyan uses a dedicated tmux socket namespace:

```sh
tmux -L banyan ls
tmux -L banyan attach -t banyan-Shell
```

This keeps Banyan sessions out of the default `tmux ls`, while still allowing manual attach/debug when needed.

## Build

```sh
swift build
```

## Run

```sh
swift run Banyan
```

For iterative UI work, use the dev watcher:

```sh
scripts/dev-watch.sh
```

It rebuilds and restarts only the Banyan client when Swift package files change. Backing `tmux -L banyan` sessions remain alive across restarts, so running agents and shells are not killed.

The app starts a local control server on `127.0.0.1:7842`.

Live terminal processes are kept by `tmux -L banyan` using session names prefixed with `banyan-`.

Session and workspace state are saved to SQLite:

```text
~/Library/Application Support/Banyan/state.sqlite
```

On first launch after upgrading, Banyan migrates legacy session metadata from `sessions.json` when the SQLite database has no sessions.

Persisted state currently includes session metadata, tmux session names, generated titles, sidebar order, selected session, sort mode, terminal theme, and terminal font settings.

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

swift run banyanctl spawn \
  --parent ENG-6685 \
  --id ENG-6685-sub-1 \
  --title "ENG-6685 subtask" \
  --cwd /Users/banyudu/dev/2enai/clawly \
  --cmd "codex"

swift run banyanctl session new \
  --title "Scratch shell" \
  --cwd "$PWD"

swift run banyanctl agent run \
  --agent codex \
  --cwd "$PWD" \
  "implement keyboard shortcuts"

swift run banyanctl agent run \
  --agent claude \
  --prompt-file /tmp/handoff-prompt.txt

swift run banyanctl mark --id ENG-6685 --status need-input --tone yellow
swift run banyanctl mark --id ENG-6685 --status review --tone purple --title "ENG-6685 review"
swift run banyanctl close --id ENG-6685
swift run banyanctl respawn --id ENG-6685
swift run banyanctl remove --id ENG-6685
swift run banyanctl list
```

`session new` is the preferred native terminal creation command; `spawn` remains as the low-level API-compatible alias. `agent run` builds an agent command, creates a Banyan session through the same control server, and lets Banyan detect the provider icon and generated title from the command. `--parent` groups a spawned session under another active session in the sidebar. Nesting can be arbitrarily deep. `close` detaches and hides the Banyan view while leaving the tmux session alive. If a closed session has child sessions, those children are detached to the closed session's parent level. `respawn` reattaches to an existing tmux session or recreates it from the saved command if it no longer exists. `remove` is destructive and kills the backing tmux session.

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

Banyan embeds SwiftTerm, so terminal applications can use ANSI, 256-color, and truecolor escape sequences for syntax highlighting and colorized output. Banyan exposes app theme and terminal font controls in Preferences.

The embedded terminal supports normal desktop text selection and clipboard shortcuts. Drag to select visible terminal text, use `Cmd+C` to copy the selection, and use `Cmd+V` to paste into the active tmux-backed session.

Theme options:

- System
- Dark
- Light

The selected theme applies to both the SwiftUI chrome, such as the sidebar, and the embedded terminal.

## Agent State Detection

Banyan watches terminal output for common agent states and can mark sessions as `need-input`, `review`, `failed`, or `completed`. It sends macOS notifications for attention states.

Coding-agent sessions launched through `claude`, `codex`, `deepseek`, `gemini`, `glm`/`zai`, `mimo`, `minimax`, or `opencode` get a compact provider badge in the sidebar. If a session has a manual title, Banyan keeps it. Otherwise it derives a title from the terminal-reported title, the prompt passed to the agent command, or a provider/project/session fallback.

For local model or cheap hosted title generation, set `BANYAN_TITLE_COMMAND` before launching Banyan. The command receives a JSON object on stdin and should print one short title on the first stdout line:

```sh
BANYAN_TITLE_COMMAND=/path/to/title-script swift run Banyan
```

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
