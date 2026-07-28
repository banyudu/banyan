# Banyan

Banyan is a native macOS session cockpit for running many long-lived agent or terminal tasks without packing every session into a grid of panes.

The first screen is the working surface:

- left sidebar: sessions, status signals, tone, title, and compact session actions
- right side: the selected terminal session
- each session is backed by a persistent `tmux` session, so agents keep running across Banyan restarts
- programmatic control is available through `banyanctl`

### Linear keyboard navigation

When the Linear sidebar is active, use `Cmd+J` / `Cmd+K` to move through issues,
`Cmd+L` to open the selected issue, and `Cmd+Return` to start a session for it.
`Cmd+Shift+L` switches to the Linear sidebar and `Cmd+Shift+S` switches back to
Sessions. The existing `Cmd+J` / `Cmd+K` shortcuts continue to move through
terminals when the Sessions sidebar is active.

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

On Linux, the package also builds a terminal frontend that runs without
SwiftUI or AppKit:

```sh
swift build --product BanyanTUI
swift run BanyanTUI
```

`BanyanTUI` uses the same SQLite session state, dedicated tmux backend, agent
status detection, and local history importer as the macOS app. In the TUI,
`j`/`k` navigate, Enter attaches or resumes, `n` creates a shell, `c` closes,
`x` removes, `R` recovers a missing backing session, `h` toggles history, and
`T` resumes history with transcript trimming. Press `q` to quit.

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

## Dev / Stable Builds

Two channels, never running at the same time (they share control port 7842 and `state.sqlite`):

- **dev** — `scripts/dev-watch.sh` (debug build, auto-rebuild on change) or `dist/Banyan.app` (packaged candidate).
- **stable** — `/Applications/Banyan.app`. Promoted explicitly by running `scripts/package-app.sh`, which stamps the git SHA into `CFBundleVersion` and archives the outgoing install to `dist/Banyan-previous.app`.

Switching is one command; it gracefully stops whichever instance is running (packaged or dev-watch debug binary), waits for the port, and launches the requested channel. Sessions survive every switch because tmux owns them:

```sh
scripts/restart-app.sh                    # relaunch the packaged candidate
scripts/restart-app.sh --stable           # switch to /Applications/Banyan.app
scripts/restart-app.sh --stable --force   # dev build is hung: SIGKILL it first
scripts/restart-app.sh --previous         # roll back to the pre-promotion stable
```

### Reboot recovery

Cmd+Q leaves the dedicated tmux server and running sessions alive. A machine
restart stops that tmux server and its child processes, while Banyan's metadata
remains in `state.sqlite`. On the next launch, active sessions whose tmux
backing disappeared are automatically recovered in the background instead of
silently waiting for one-by-one manual actions. Codex and Claude sessions use
their saved provider session ID to resume when available; ordinary shells and
sessions without a resumable provider session recreate their saved launch
command. Failed recoveries remain available through the selected-session
**Recover** button, row context menu, or sidebar **Recover All** action.

Check which build an install is: `defaults read /Applications/Banyan.app/Contents/Info CFBundleVersion`.

Older stable builds can read a newer `state.sqlite` because migrations are additive only (`CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ADD COLUMN`) — keep them that way.

## iTerm2 Rescue

If the Banyan app is hung or broken, all sessions are still reachable — they are plain tmux sessions. The rescue script lays them out in iTerm2, one tab per project and one pane per session:

```sh
scripts/iterm-rescue.sh              # attach everything
scripts/iterm-rescue.sh --dry-run    # print the tab/pane plan
scripts/iterm-rescue.sh -p clawly    # only one project
scripts/iterm-rescue.sh -d           # kick other clients (including a wedged Banyan)
```

It talks to tmux and `state.sqlite` directly and never depends on the Banyan app or control server. Terminal content stays in sync with Banyan automatically because both are tmux clients of the same sessions; closing panes only detaches them.

## Performance Telemetry

Banyan collects local, CWV-like performance events for app-specific workflows such as switching sessions, attaching terminals, refreshing tmux clients, and resolving selected-session context. The data is stored locally in:

```text
~/Library/Application Support/Banyan/state.sqlite
```

Use the CLI report before investigating performance issues:

```sh
dist/bin/banyanctl perf report --since 7d
dist/bin/banyanctl perf report --since 7d --json
```

Important metrics include `session_switch.total`, `session_switch.to_terminal_ready`, `session_switch.to_first_output`, `terminal.ready_wait`, `terminal.start_client`, `terminal.reattach_client`, `tmux.refresh_clients`, and `selected_context.resolve`.

To turn the collected report into a targeted agent task:

```sh
dist/bin/banyanctl perf prompt --since 7d
dist/bin/banyanctl perf fix --since 7d --agent codex --cwd "$PWD"
```

`perf fix` does not silently rewrite the running app. It creates a Banyan-native coding-agent session with the local telemetry report as evidence, so fixes still go through normal code review and test flow.

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

Coding-agent sessions launched through `claude`, `codex`, `deepseek`, `gemini`, `glm`/`zai`, `mimo`, `minimax`, or `opencode` get a compact provider badge in the sidebar. If a session has a manual title, Banyan keeps it. Otherwise it derives a title from the terminal-reported title, the prompt passed to the agent command, the first prompt submitted interactively, or a compact provider/session fallback.

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
