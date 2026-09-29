# Offline puck integration fixture

This fixture checks the shared daemon path with no live subscription, Slack
workspace, or other tool's credentials. It needs a macOS Banyan build, tmux,
and puck binaries containing the loopback-only `PUCK_SLACK_API_BASE` test hook.

Build from the two checkouts, then run from Banyan:

```sh
(cd ../puck && cargo build -p puck-daemon -p puck-cli)
swift test --quiet --filter appPuckBrowserSeesSharedDaemonSessionAndItsEvents
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

The same session is opened through the app's `PuckSessionBrowser` in a fresh
Swift test process, the interactive BanyanTUI list and attach flow, and
`banyanctl session list` and `puck attach`. A later turn must appear both in the
app browser's structured events and in the fake Slack session thread. The app
browser test then runs again in another process to verify replay after a
frontend restart. The test exercises the app client code without launching a
macOS window. It does not check a live Slack installation or phone tap.

Temporary state and synthetic keys are removed when the script exits. The
printed JSON records the measured RSS values and pass statuses; the ratio is
specific to the local machine and this short-history fixture.
