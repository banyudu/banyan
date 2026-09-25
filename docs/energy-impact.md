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
  includes total, frequently observed, and deferred session counts plus the
  selected cadence.
- `supervisor.session` is retained only when one tmux/process inspection takes
  at least 150 ms; it includes the Banyan session ID to identify a slow pane.
- `history.import` measures a full local agent-history refresh. It is retained
  when the refresh takes at least 500 ms and includes the imported session count.
- `terminal.draw` is retained only when a draw takes at least 16 ms. Fast draws
  are deliberately not written to SQLite so telemetry cannot create persistent
  background I/O during output-heavy sessions. Its detail carries `renderer=cg`
  or `renderer=metal`, so samples from the two renderers can be told apart; see
  `docs/terminal-renderer-experiment.md`. `BANYAN_TERMINAL_DRAW_PROFILE=1`
  retains every sample instead of only the slow ones, which is what an A/B run
  needs to compute an average and a p95.

The supervisor invokes `ps` once and batches pane metadata for all started
sessions into one tmux command per tick. It still captures visible text only for
sessions with a live coding agent, because that text is needed for status
detection.

Closing a Banyan session moves its existing in-memory row into History and
updates its recency; it does not import provider transcripts. The history
sidebar projection is cached and invalidates when that row changes. Full
imports run only when a workflow requests fresh transcript metadata. They reuse
parsed Codex and Claude transcript metadata while file size and modification
date are unchanged. Codex title-index notifications update known session titles
directly, without importing transcripts.

Restoration also avoids Git subprocesses for closed history rows. A large local
history can contain thousands of old working directories; resolving each one
before starting the control server delayed launch and caused a CPU spike.
Closed rows use their saved path for display and retain their historical issue
link. Active rows still resolve the current checkout. The main window also
stops launching a full external-agent transcript import on every startup;
persisted sessions already contain their titles and provider IDs. Other
workflows can request an import when they need fresh transcript metadata.

Live samples after the history fix found a second draw cost: CoreGraphics
rebuilt most rows in full-screen agent panes, then spent most of that draw time
running implicit-link detection's ICU regex. Per-row caching cannot help when
the pane rewrites those rows. Banyan now resolves plain-text links when the
user Cmd-hovers or Cmd-clicks them, instead of coloring every detected link on
every frame. Links remain clickable and highlight under the pointer, while
ordinary output avoids regex work during drawing.

## Idle behavior and background throttling

Banyan cannot ask to be App Napped — no API grants that, and an app with any
window on screen on any Space is disqualified whatever it does. Nap would also
only defer timers; it would not stop the subprocesses those timers spawn, which
is where the energy actually goes. So the app reads the same signal the OS reads
(`NSApplication.occlusionState`) and throttles itself.

Visibility is three states, not two. "Frontmost or not" is too coarse: an app on
screen behind another one still has to keep its status dots honest.

- `active` — frontmost.
- `backgroundVisible` — not frontmost, but a window is on screen and not fully
  covered.
- `hidden` — hidden, miniaturized, or every window occluded. Nothing Banyan
  draws can be read, which is the only state that is free to throttle hard.

Supervisor cadence, before the existing session-count, low-power, and thermal
multipliers:

| Visibility | Agent executing | Idle |
| --- | --- | --- |
| `active` | 2 s | 6 s |
| `backgroundVisible` | 6 s | 15 s |
| `hidden` | 30 s | 300 s |

A tick is the only thing that turns an *unattached* session's new state into a
notification, so hidden cadence is also the worst-case attention latency for a
session the user has never opened. Attached sessions are unaffected: their
status signals arrive on the PTY as the agent writes them, so the session the
user is actually watching still notifies instantly at any visibility. An idle
agent cannot change without the user, which is why that case stretches to the
ceiling while an executing one keeps a half-minute check. The session-count
multiplier applies only to on-screen cadences — it exists to flatten spikes in a
two-second poll, and at half a minute there is no spike to flatten.

Refreshes that feed on-screen chrome only are treated separately, because they
raise no notification and persist no decision. The branch chip's git sweep runs
every 15 s frontmost, every 60 s on screen but not frontmost, and **not at all
while hidden**; the selected session's Linear status poll is gated the same way.
This is the largest single saving: each cycle spawns several `git` invocations
per distinct working directory, so a workspace with 30-odd worktrees was
spawning on the order of 80 processes every 15 seconds, around the clock,
regardless of whether anyone could see the result.

Becoming visible again runs an immediate forced supervisor tick and forces both
chrome refreshes, so the first frame the user sees is re-synced rather than
showing what was true when the window was covered. tmux holds the scrollback
throughout, so throttling changes only when Banyan looks, never what it can find.

### Why sessions are not auto-parked

Parking on an idle timer was considered and rejected. Backoff already collapses
the cost: a deferred session is filtered out of the tick's inputs entirely, so it
costs nothing, and quiet sessions reach a one-hour interval on their own. Parking
would save almost nothing on top of that, and it costs correctness — nothing
observes a parked session, and `SessionLifecyclePolicy.needsAttention` excludes
one, so a session auto-parked while quiet would drop out of attention navigation
and notifications the moment its agent needed input. Parking stays an explicit
statement of user intent ("I am done with this for now"), not something inferred
from quiet.

Sessions the user has parked (`banyanctl suspend`, or Suspend in the sidebar
context menu) are excluded from the tick entirely, along with branch/context
refresh, selected-context refresh, and terminal rendering. `supervisor.tick`'s
`sessions=` detail counts only unparked sessions, and no `supervisor.session`
event is written for a parked one, so tick cost tracks the working set rather
than the number of open sessions. Their tmux sessions and agents are untouched;
a single `tmux list-sessions` sweep, at most hourly regardless of how many are
parked, notices one whose backing session exited.

Each session also backs off independently after repeated identical
observations. Quiet sessions progress from the normal cadence to 2x, 4x, 8x,
and longer intervals, capped at one hour. If every session is backed off, the
supervisor timer sleeps until the next session is due. A user status signal or
selecting a session resets that session's backoff.

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
