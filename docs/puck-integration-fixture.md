# Offline puck integration fixture

This fixture checks the shared daemon path with no live subscription, Slack
workspace, or other tool's credentials. It needs a macOS Banyan build, tmux,
and puck binaries containing the loopback-only `PUCK_SLACK_API_BASE` test hook.

Build from the two checkouts, then run from Banyan:

```sh
(cd ../puck && cargo build -p puck-daemon -p puck-cli)
swift test --quiet --filter appPuckSessionSeesSharedDaemonSessionAndItsEvents
swift build
python3 scripts/verify-puck-integration.py \
  --puckd ../puck/target/debug/puckd \
  --puck ../puck/target/debug/puck \
  --banyanctl .build/debug/banyanctl \
  --banyantui .build/debug/BanyanTUI
```

The script creates a private temporary `PUCK_HOME`, an opaque synthetic Codex
seat, and local Responses and fake Slack HTTP/WebSocket endpoints. It creates 35
sessions, completes a turn in each, and keeps their daemon runtime attachments
idle. It measures the daemon's RSS against one completed idle `puck chat`
process and requires the ratio to be below 25% of 35 CLI processes. It checks
that the idle daemon has no child processes.
Before starting BanyanTUI, it asserts that `BANYAN_FIXTURE_DATA_HOME` resolves
its SQLite path inside the temporary directory. The same override supplies the
TUI's home for history discovery. Without this variable, Banyan's normal data
directory behavior is unchanged.

The same session is opened through the app's session store in a fresh Swift
test process, where the daemon listing adds it as a `PuckSession` that the test
then follows, the interactive BanyanTUI list and attach flow, and
`banyanctl session list` and `puck attach`. A later turn must appear both in the
followed session's structured events and in the fake Slack session thread. The
app test then runs again in another process to verify replay after a frontend
restart. The test exercises the app's store and session code without launching
a macOS window. It does not check a live Slack installation or phone tap.

The fixture also runs a long-lived app watch against the real daemon, reports
desk activity, and parks a question. It checks the ask's `interactive` route
and that fake Slack posts nothing. After answering, the app reports display
sleep through its presence monitor; the fixture checks Slack's catch-up and
that a second question on the same session routes to `notify`. Unit tests
exercise lock, display sleep, app deactivation, automatic reconnection,
cursorless lag markers, and events interleaved with presence RPC replies.
Finally the fixture restarts puckd while the app follows a session, requires
automatic replay with the same cursors, and verifies a new turn arrives live.

Temporary state and synthetic keys are removed when the script exits. The
printed JSON records the measured RSS values and pass statuses; the ratio is
specific to the local machine and this short-history fixture.
