# Energy Impact investigation

Banyan's Energy Impact row is not a reliable process-tree accounting boundary.
The app owns each visible `tmux attach-session` client, but tmux servers and
agent processes can outlive or be re-parented independently. macOS does not
expose a supported way to prove that an agent's energy use is charged to the
Banyan row. Treat Activity Monitor as an app-level symptom, then measure the
app, tmux server, and agent processes separately.

## What Banyan measures

`banyanctl perf report --since 7d --json` records Banyan-owned work. In
particular:

- `supervisor.tick` identifies the periodic session-inspection batch. Its detail
  includes total, active, and idle session counts plus the selected cadence.
- `supervisor.session` is retained only when one tmux/process inspection takes
  at least 150 ms; it includes the Banyan session ID to identify a slow pane.
- `terminal.draw` is retained only when a draw takes at least 16 ms. Fast draws
  are deliberately not written to SQLite so telemetry cannot create persistent
  background I/O during output-heavy sessions.

The supervisor invokes `ps` once and batches pane metadata for all started
sessions into one tmux command per tick. It still captures visible text only for
sessions with a live coding agent, because that text is needed for status
detection. Active sessions retain a 2-second foreground cadence. When all
started sessions are idle, the cadence becomes 6 seconds in the foreground and
15 seconds in the background, before existing session-count, low-power, and
thermal backoff is applied.

## Reproduction and attribution

1. Run several tmux-backed agent sessions and collect the performance report.
2. In Activity Monitor, inspect Banyan, each `tmux` server, and each agent
   process separately. Record PID, parent PID, CPU, wakeups, and Energy Impact.
3. Correlate the observation timestamps with `supervisor.tick` entries. A
   recurring slow tick with the same session count points to Banyan's status
   supervision; a slow `supervisor.session` names the pane to inspect.
4. Compare an idle workspace with the same workspace while one agent is
   generating output. Energy that follows the agent process but not a Banyan
   metric is agent/tmux workload, not Banyan rendering or supervision.

Activity Monitor's Energy Impact is a rolling, platform-defined estimate, so it
can remain high after instantaneous CPU falls. It should not be used alone to
assign terminal-server or agent energy to Banyan.
