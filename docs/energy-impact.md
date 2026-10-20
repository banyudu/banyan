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

- `supervisor.tick` identifies the periodic session-inspection batch and is
  retained when it takes at least 150 ms. Its detail includes total, observed,
  and deferred session counts, the scheduled delay, and the next delay/effective
  cadence after completion. Supervisor percentiles describe retained slow
  samples, not a complete census.
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

The supervisor batches pane metadata into one tmux command per tick and takes
one process snapshot only when classification is due. Darwin uses kernel APIs;
other platforms use `ps`. Captures for live coding agents reuse unchanged pane
text. Stable executing sessions back off, while output/process events and a
bounded activity probe preserve responsiveness. See
[supervisor cadence](supervisor-cadence.md) for scheduling, measured fixture
counts, and the isolated runtime verification recipe.

Closing a Banyan session moves its existing in-memory row into History and
updates its recency; it does not import provider transcripts. The history
sidebar projection is cached and invalidates when that row changes. Full
imports run only when a workflow requests fresh transcript metadata. They reuse
parsed Codex and Claude transcript metadata while file size and modification
date are unchanged. Codex title-index notifications update known session titles
directly, without importing transcripts.

Routine live-session changes persist only that session's SQLite row. Previously
each title/status update rebuilt snapshots for every closed session on the main
thread, then deleted and reinserted the entire sessions table in the background.
With thousands of closed sessions, a live process sample showed both operations
consuming substantial CPU. Full-table saves remain for structural changes such
as adding, removing, or reordering sessions.

The control server returns active sessions by default, filtering closed history
before constructing detailed rows. `--all` includes history; exact `--id` and
`--query` lookups avoid serializing unrelated sessions. CPU spike
captures identified per-row `ISO8601DateFormatter` construction as a dominant
cost: each request rebuilt two formatters for every saved session. Response
timestamps now use `Date.ISO8601Format()`, preserving UTC and second precision
without rebuilding ICU formatters.

`--all` is still a large response: on a 2,580-session local history it produced
about 4.5 MB and took roughly half a second per request. Prefer the active
default, exact `--id`/`--query` lookups, or the event stream unless closed
history is genuinely required. A maintenance client that polls `--all` can make
the Banyan process look busy even while its UI is idle. The control server still
pretty-prints and sorts the complete response; compact output or a lighter
history projection is a candidate optimization, but should be justified with a
matching workload capture rather than assumed.

The active sidebar excludes closed history before resolving display titles or
constructing its lookup. It also has a revision-keyed cache, so a cache hit is a
single integer comparison rather than a walk over every active row. The revision
bumps when the session array, selection, sort mode, child-visibility controls,
or any presentation field on a session changes. `isImportedHistory` is derived
from an immutable transcript URL, so it cannot change without replacing the row.
History retains its separate projection and cache. That cache is keyed by a
revision bumped only when a row enters, leaves, or changes inside History. Both
projections previously hashed their rows on every SwiftUI pass; even a cache hit
then scaled with the fleet or full local history and dominated the main thread
while streaming output or switching sessions.

Navigation menu availability checks also avoid the history projection whenever
visible active rows determine the answer. Two active rows enable next/previous
navigation without inspecting history; workable-session availability only
inspects visible active rows, because closed history cannot be workable. With
fewer than two active rows, next/previous availability still counts visible
history entries. Actual navigation continues to use the complete sidebar order.

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

Output-triggered wakeups also respect the active-work cadence for the current
visibility, Low Power Mode, and thermal state. Previously their fast path always
scheduled a check in two seconds, bypassing hidden throttling while PTY output
continued. Chunks still coalesce into one deadline without scanning the fleet.
Input, explicit status, and process-exit signals retain their two-second
inspection deadline; returning to the app still forces a refresh. Hidden
attention inferred only from pane text follows the hidden output cadence.

A tick is the only thing that turns an *unattached* session's new state into a
notification, so hidden cadence is also the worst-case attention latency for a
session the user has never opened. Explicit status signals still arrive directly;
attention inferred from raw terminal text uses the visibility-aware inspection
cadence, including for attached hidden sessions. An idle
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

### Verify a recurring regression

Compare the same build configuration, power/thermal state, session count,
history size, and workload before and after each fix. A quiet ten-second sample
cannot clear an intermittent regression, and the rolling 12-hour score cannot
measure the immediate effect of a patch.

Use these separate phases, keeping CPU/wakeup samples and spike captures:

| Phase | What it isolates |
| --- | --- |
| Visible, quiet sessions | Baseline UI and supervisor overhead |
| Hidden, quiet sessions | Work that should stop or back off |
| Hidden, continuous terminal output | Output bypassing background throttling |
| Repeated session switches with a large history | Sidebar projection, menu creation, and layout |
| Completion/attention while hidden, then reveal | Notification latency and correct resynchronization |

Replay the affected fleet size rather than only testing a fresh one-session
workspace. For UI spikes, correlate the capture's selection and visibility
with the switch events. `BANYAN_TERMINAL_DIAGNOSTICS=1` enables aggregated
terminal update/layout/frame-change/output/draw counters; see
`TerminalEnergyDiagnostics`. A layout stack identifies where time was spent,
not which state change invalidated the view. Use a SwiftUI Instruments trace
to follow that dependency before changing row observation or animations.
Do not sum asynchronous telemetry durations as if they were CPU time.

The continuous-output scheduler regression simulates five minutes: normal-power
hidden output permits ten scheduled checks instead of the former 150. This is
a scheduling assertion, not a claim of a proportional reduction in battery use.
The isolated runtime fixture in [supervisor cadence](supervisor-cadence.md)
checks real timers and hidden notification paths on disposable tmux sessions.

Only mark the recurring incident resolved after the patched app passes the
matching workload phases and remains quiet through an ordinary work period.
Keep capturing recurrences with build IDs so a later regression can be
distinguished from an old binary or a separate expensive path.

### Run an isolated lab instance

`scripts/lab-app.sh --package --here` copies the packaged app under
`/tmp/banyan-lab`, then launches it with a private data directory, control port
(`7843` by default), and tmux socket. The copied bundle path also keeps
`scripts/restart-app.sh` from treating the lab instance as the production
channel. It sets `BANYAN_LAB=1`, which skips the update check and global jump
shortcut monitor; `BANYAN_CPU_CAPTURE=0` avoids the spike sampler perturbing the
measurement. The script writes an `env.sh` so `banyanctl` targets the lab:

```sh
scripts/lab-app.sh --package --here
source /tmp/banyan-lab/env.sh
banyanctl session list
```

`BANYAN_ENERGY_TRACE=1` adds causal counters at the PTY-output, session-change,
sidebar-invalidation, view-body, and layout boundaries. They aggregate in
memory and emit one `energy-trace` line every five seconds, so a trace shows
which event spikes immediately before a layout burst without turning terminal
output into per-chunk logging. Stream it with:

```sh
log stream --predicate 'subsystem == "dev.banyudu.banyan" AND category == "energy-trace"' --info
```

The same switch enables `os_signpost` intervals, so a short Instruments run can
correlate those counters with the main-thread stacks. The trace is off in
ordinary launches; the lab overrides are inert unless their environment keys
are set.

### Attribute the workload before changing the app

```sh
banyanctl perf energy --seconds 10
banyanctl perf energy --seconds 10 --json
```

This macOS-only, read-only report takes two kernel process inventories and two
batched tmux pane inventories. It groups CPU, interrupt wakeups, physical memory,
and available CPU energy counters by Banyan session, and lists the busiest
processes with their PIDs and ages. The app PID and Banyan's tmux server are
separate groups. No app restart, control-server request, privilege escalation,
background timer, process signals, arguments, environment, or transcript reads
are involved. Sampling defaults to 10 seconds and is bounded to 1–60 seconds.

This matters when an agent leaves a command running after useful work finishes.
For example, a stuck startup helper can consume a core and thousands of wakeups
per second for days. Optimizing the terminal view does not stop that command;
an app-only CPU spike capture does not detect it. Confirm the owning session and
command before cancelling it. Do not automatically kill jobs based on their age
or CPU usage: a long build or server can be intentional.

The same rule applies to unrelated maintenance work. In one recurrence, the
10-second report charged about 6.2% CPU to Banyan, 7.9% to the active agent,
and 1.6% to the tmux server, while processes outside the Banyan groups accounted
for roughly 220% across the machine. A separate worktree-maintenance job peaked
at about 36% CPU, had accumulated more than eight CPU-minutes, and spent its
sample in recursive filesystem deletion. Its run record lasted over 30 minutes,
deferred more than a hundred decisions after its budget, and contained a single
checkout removal taking over 100 seconds. That explains a real battery symptom,
but it is not a Banyan rendering or supervision loop. When such a client also
polls `banyanctl list --all`, it can additionally raise Banyan's own CPU without
the app being idle-busy; attribute both the maintenance process and each control
request before changing the sidebar or terminal renderer.

The report is a current process-tree measurement, not a reconstruction of
Activity Monitor's accounting. **12 hr Power is a historical average**, while
Energy Impact describes current activity. CPU energy counters are not total
battery power. Process ancestry associates jobs with panes even when tmux has
been reparented to launchd, but independently reparented jobs appear as `other`.
Unreadable processes are counted, and new, exited, replaced, or reassigned PIDs
are excluded from deltas. Work that starts and exits between the two inventories
is not measured. A failed tmux inventory produces an explicit coverage warning.
JSON retains all measured rows; the text report shows the top 20 processes.

For recurring incidents, save the JSON during the symptom and compare the
same workload after the targeted fix. Keep raw evidence outside the repository.
App-only slow-event percentiles and spike captures complement this report;
they do not establish that Banyan's own process caused the battery drain.

### Automatic CPU spike captures

The macOS app monitors its own process counters on a utility queue independent
of the main thread. There is no CPU-change notification, so detecting an
unprompted spike requires polling: every 5 seconds while active with started
sessions, 10 seconds otherwise, or 15 seconds on battery or in Low Power Mode.
The timer has coalescing tolerance. It performs one kernel resource read, without
scanning process trees or calling tmux. Between spikes, the last 60 intervals
stay in memory and generate no disk writes.

A capture starts after two consecutive intervals at or above 50% CPU, or 20%
while hidden. An interval at or above 100% starts one immediately. CPU percentage
uses actual elapsed time and Mach timebase conversion; 100% means one occupied
core. These thresholds are CPU thresholds, not Activity Monitor Energy Impact.

Each capture runs `/usr/bin/sample` for 3 seconds at 10 ms intervals, with a
15-second process timeout. The profiler runs on a separate queue. Its intervals
are excluded from spike detection, and counters are re-baselined afterwards.
There is a five-minute cooldown and at most six attempts per rolling hour,
including failures. Recent attempts restore this budget after an app restart.
Metadata records failures when macOS does not permit sampling.

Captures are local under Banyan's data directory at `Diagnostics/CPU/<id>/`:

- `capture.json`: app build, startup age, cached visibility/power/selection
  context, and recent CPU, interrupt wakeup, disk I/O, and memory intervals.
  Kernel CPU energy accounting is included when the OS supports it; it is not
  whole-device battery power or Energy Impact. These counters cover Banyan's
  process only, excluding tmux, agents, and the profiler child.
- `stack.txt`: the stack sample, capped at 2 MiB, with truncation noted in JSON.

Startup and capture cleanup retain at most 20 captures for up to 14 days,
including incomplete captures. Completed captures use roughly 40 MiB at most
for stacks, plus small metadata files. Directories and files are private to the
current user. Stack symbols may include local paths; nothing is uploaded, and
no terminal text, transcripts, environment, or command arguments are collected.

```sh
dist/bin/banyanctl perf captures --since 12h
dist/bin/banyanctl perf captures --since 12h --json
dist/bin/banyanctl perf report --since 12h
```

`perf captures` reads local files without requesting work from the app. The
performance report includes `resource.cpu_spike` events with the capture path;
their duration is CPU time consumed during the triggering interval. An
interrupted capture remains marked `capturing` in its metadata. Set
`BANYAN_CPU_CAPTURE=0` in the app's launch environment to disable the monitor.
This captures future app spikes; it cannot reconstruct historical agent usage
or catch a burst shorter than the sampling window that averages below threshold.

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
