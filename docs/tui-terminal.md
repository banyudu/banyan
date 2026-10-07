# Embedded TUI terminal

BanyanTUI renders the selected tmux session inside its right pane. The sidebar
stays visible while shells, editors and coding agents receive input. The
session list, history, recovery and lifecycle actions still use BanyanCore.

- Enter focuses the terminal. Ctrl-] followed by ] returns to the sidebar.
- Ctrl-] followed by j/k switches sessions without terminating their shells.
- Ctrl-] followed by Ctrl-] sends a literal Ctrl-] to the terminal.
- Tmux's configured prefix remains available. With the default prefix,
  Ctrl-B followed by [ opens copy mode for scrollback; q exits copy mode.
- In the sidebar, f opens the existing full-screen attachment as a fallback.
- Terminal mouse reports are supported when tmux requests them. Reports outside
  the right pane are ignored. Bracketed paste does not trigger Banyan shortcuts.
- Resize follows SIGWINCH. Narrow windows hide the sidebar until there is room.

## Design

The original TUI blocked on keyboard input and then handed its stdin/stdout to
tmux. A preview capture cannot provide interactive terminal state or redraw on
asynchronous output. The previous control-mode prototype also lacked screen
reconstruction, safe reconnect and complete terminal parsing.

This implementation uses the issue's PTY bridge alternative. Tmux renders its
client into a private PTY sized to the right pane. The portable vendored
SwiftTerm model parses that stream; a cell adapter renders ANSI colors, text,
wide characters, cursor visibility/style and alternate screens into the host
terminal. Tmux supplies a fresh screen on each attachment and retains its own
scrollback across switches and TUI restarts. Copy mode therefore works for
history produced before this client attached, too.

Control mode would avoid tmux's client-side rendering, but requires coherent
capture/output ordering and explicit restoration of cursor, modes, history and
alternate-screen state. A custom minimal ANSI parser would duplicate SwiftTerm
and omit common terminal behavior. The PTY path keeps those responsibilities
with tmux and SwiftTerm. There is no control-mode protocol parser in this design;
regression coverage exercises the equivalent PTY stream, input parser and
terminal model instead.

Reads, process exits and OS signals wake the UI through callbacks and a
self-pipe. There is no idle repaint timer. Output schedules one frame at most
every 33 ms, and unchanged rows/cursor state produce no host writes. A client
generation discards old output and exit callbacks after a switch. Detach closes
only that client's PTY and reaps only that child; it does not kill the server or
backing shell. Unexpected exits get three bounded reconnect attempts with
one-shot delays; Enter retries after that. Nothing repeatedly polls a dead
session.

Linux builds exclude SwiftTerm's AppKit/UIKit and Metal sources/resources. The
small C helper performs the post-fork setup and exec without invoking Swift in
the child. It sets up a controlling tty, closes inherited descriptors, forwards
window dimensions with TIOCSWINSZ, and retains PID ownership until reaping.

On Linux, the first `new-session` command also uses an owned C spawn and direct
child-exit notification. Foundation's inherited exit-monitoring socket can stay
open in the new tmux daemon after its launcher exits, delaying notification and
reaping. This path closes inherited descriptors, snapshots and drains every
buffered stdout and stderr byte at direct-child exit, and returns even if a
detached grandchild holds or keeps writing to the pipes. Other tmux commands and
the shared SubprocessRunner retain their existing implementation, including
cancellation behavior.

## Verification

```sh
swift build --product BanyanTUI
swift test --filter BanyanTUITests
swift test --filter 'tmuxDaemonCommand|subprocessRunner'
python3 scripts/tests/test_embedded_terminal.py
```

The smoke harness runs the actual TUI in a PTY with a disposable database, home
directory and unique tmux socket. It checks input, live output without keyboard
activity, colors, resize, copy mode/history, alternate screens, session switch,
client detach/reconnect and restart. It signals only its own TUI child and
detaches clients only on its private server. Linux CI runs this harness too.

The fixture overrides require both `BANYAN_FIXTURE_DATA_HOME` and a socket named
`banyan-tui-fixture-*` in `BANYAN_FIXTURE_TMUX_SOCKET`. Without an explicit fixture
socket, a private random socket is used whenever a fixture data home is set.

Human checks: run a preferred coding agent, editor and pager in a disposable
session; check host-specific keyboard/mouse behavior and display widths. Bitmap
graphics and host clipboard integration are not exposed by the cell renderer.
Pane sizing continues to follow the tmux server's configured multi-client size
policy, as with normal tmux attachment.
