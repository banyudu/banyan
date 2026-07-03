# Banyan Testing Model

Banyan uses two testing layers:

1. Object-oriented UI automation through stable accessibility identifiers.
2. Visual validation through screenshots captured from the packaged app.

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
| Sidebar edit selected button | `banyan.sidebar.edit-selected` |
| Sidebar close selected button | `banyan.sidebar.close-selected` |
| Toolbar logo | `banyan.toolbar.logo` |
| Toolbar add button | `banyan.toolbar.add-session` |
| Toolbar preferences button | `banyan.toolbar.preferences` |
| Session row | `banyan.sidebar.session-row.<session-id>` |
| Session row title | `banyan.sidebar.session-row.<session-id>.title` |
| Session row status | `banyan.sidebar.session-row.<session-id>.status` |
| Detail area | `banyan.detail` |
| Empty detail area | `banyan.detail.empty` |
| Terminal container, including text selection, copy/paste, and wheel scrolling | `banyan.terminal` |
| Terminal header | `banyan.terminal.header` |
| Terminal title | `banyan.terminal.header.title` |
| Terminal directory | `banyan.terminal.header.directory` |
| Terminal command | `banyan.terminal.header.command` |
| Terminal attach button | `banyan.terminal.header.attach` |
| Add session sheet | `banyan.sheet.add-session` |
| Edit session sheet | `banyan.sheet.edit-session` |
| Preferences sheet | `banyan.sheet.preferences` |

## Semantic Actions

Automation should describe Banyan in product terms:

- `launchApp`
- `spawnSession(id:title:cwd:command:)`
- `selectSession(id:)`
- `markSession(id:status:tone:)`
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
