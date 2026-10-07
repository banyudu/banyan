# Banyan Testing Model

Banyan uses two testing layers:

1. Object-oriented UI automation through stable accessibility identifiers.
2. Visual validation through screenshots captured from the packaged app.

Runtime startup has a windowless regression suite on macOS:
`swift test --filter AppStartupTests`. It invokes the native app-delegate launch
callback without creating a view, and checks authenticated control requests,
restoration before default spawning, and repeat-start idempotency. The suite
uses a private database, home directory, tmux socket, and ephemeral control port.
`python3 scripts/tests/test_restart_app.py` checks restart recovery and bounded
failure using fake OS commands, without launching or quitting a real app.

## Object Map

These identifiers are defined in `Sources/Banyan/AccessibilityIdentifiers.swift`.

| Object | Identifier |
| --- | --- |
| App root | `banyan.root` |
| Sidebar | `banyan.sidebar` |
| Sidebar list | `banyan.sidebar.list` |
| Sidebar footer | `banyan.sidebar.footer` |
| Sidebar add button | `banyan.sidebar.add-session` |
| Sidebar options menu | `banyan.sidebar.options` |
| Toolbar logo | `banyan.toolbar.logo` |
| Toolbar add button | `banyan.toolbar.add-session` |
| Toolbar preferences button | `banyan.toolbar.preferences` |
| Session row | `banyan.sidebar.session-row.<session-id>` |
| Session row title | `banyan.sidebar.session-row.<session-id>.title` |
| Session row status | `banyan.sidebar.session-row.<session-id>.status` |
| Session row parked badge | `banyan.sidebar.session-row.<session-id>.suspended` |
| Detail area | `banyan.detail` |
| Empty detail area | `banyan.detail.empty` |
| Terminal container, including text selection, copy/paste, and wheel scrolling | `banyan.terminal` |
| Terminal reconnect banner | `banyan.terminal.reconnect-banner` |
| Terminal attach button | `banyan.terminal.reconnect-banner.attach` |
| Terminal parked banner | `banyan.terminal.suspended-banner` |
| Terminal resume button | `banyan.terminal.suspended-banner.resume` |
| Add session sheet | `banyan.sheet.add-session` |
| Preferences sheet | `banyan.sheet.preferences` |

## Semantic Actions

Automation should describe Banyan in product terms:

- `launchApp`
- `spawnSession(id:title:cwd:command:)`
- `selectSession(id:)`
- `markSession(id:status:tone:)`
- `suspendSession(id:)`
- `resumeSession(id:)`
- `closeSession(id:)`
- `removeSession(id:)`
- `relaunchApp`
- `assertTmuxSessionExists(id:)`
- `assertTmuxSessionMissing(id:)`
- `selectTerminalText(from:to:)`
- `copyTerminalSelection()`
- `pasteIntoTerminal(text:)`
- `scrollTerminal(direction:amount:)`
- `captureMainWindowScreenshot(name:)`

Coordinate clicks should be reserved for visual debugging. Routine tests should prefer the control API, tmux assertions, and accessibility identifiers.

Terminal text selection, clipboard shortcuts, and wheel scrolling are intentionally modeled as actions on `banyan.terminal` rather than separate controls. Selection and copy/paste are AppKit interactions against the embedded SwiftTerm view; wheel events may become SwiftTerm scrollback actions or tmux mouse-wheel reports depending on the terminal mode.

## Visual Validation

The native Codex conversation also has a fixture-driven, isolated macOS render
test. It uses a private database/home and in-memory App Server, and renders an
offscreen window without restarting Banyan or touching a live tmux session:

```sh
BANYAN_CODEX_RENDER_DIR=/tmp/banyan-codex-ui swift test --filter CodexConversationUITests
swift test --filter 'codexConversation|codexSteering|codexLateTurn|codexTurnCompletion'
```

Inspect `/tmp/banyan-codex-ui/conversation.png` for Markdown, command output,
reviewable file diffs, request buttons, and the composer. The suite also checks
background session routing, steering, error/draft preservation, approval and
input response payloads, cancellation, and safe cache release/revisit. Core
stress coverage streams 8 MiB into a command and exercises history/item and
unknown-payload budgets. Live checks still need an authenticated supported
Codex CLI: complete a real prompt, approve/decline command and file requests,
answer/skip/cancel input, switch sessions while streaming, interrupt, and
reconnect to the same thread after restarting an isolated app/server.

Use `scripts/validate-ui.sh` to exercise the packaged app and write screenshots to `artifacts/ui-validation/`.

The script captures visual artifacts through Banyan itself:

```sh
dist/bin/banyanctl screenshot --output artifacts/ui-validation/main.png
```

This asks the running app to render its own main window content to PNG, which avoids relying on macOS Screen Recording permission. The script falls back to `screencapture` only if the internal capture route fails.

The script verifies:

- the packaged app launches
- `banyanctl` can spawn and mark a session
- the backing `tmux -L banyan` session exists
- the app can quit and reopen without killing the session
- the session remains visible through `banyanctl list`
- screenshots are captured before and after relaunch
- cleanup removes the temporary tmux session

Screenshots are intentionally kept as artifacts for human or agent review. They complement object tests by catching layout, clipping, padding, color, and rendering regressions.
