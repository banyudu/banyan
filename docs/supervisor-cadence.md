# Supervisor observation cadence

An executing status can remain unchanged for minutes. It is not a reason to
repeat every expensive observation at the foreground cadence. Activity or a
state change opens a 10-second fast window; after three unchanged observations,
executing, long-running-shell and subagent sessions back off exponentially to
60 seconds. A slower power/thermal base interval still takes precedence.
Selected sessions with a running terminal client retain the base cadence.
Idle-session backoff retains its existing one-hour ceiling.

PTY output, submitted input, status signals and kernel process-exit events wake
deferred work, coalesced behind a two-second deadline and any running tick.
Output preserves a usable in-flight status result; newer status/input/exit
signals invalidate it. The process watcher uses PIDs from the same inspection
snapshot, creates no tmux client, and stops watching removed or suspended rows.

Evicted/unattached terminals have no PTY output callback. While executing, a
batched pane-activity probe remains due at most every 30 seconds in normal power
conditions, even when classification backs off. A changed pane is classified in
that tick. Observed processes exiting wake classification without output. A
silent transition that has neither event falls back to the bounded observation
interval. Timer tolerance (25%), main-thread scheduling and inspection duration
also contribute to observed latency; these intervals are not real-time SLAs.

Each tick fetches pane metadata once, then takes one process snapshot only if
classification is due. The synchronizer reuses those panes and the cross-tick
capture cache. Polling uses a one-shot timer rearmed after completion, so a slow
tick consumes due requests without accumulating catch-up ticks. Selected
context expiry and branch/git refresh run on the existing visible-only branch
refresh timer, separately from supervision.

## Reproduce the isolated benchmark

```sh
BANYAN_SUPERVISOR_BENCH_DIR=/tmp/banyan-supervisor-bench \
  swift test --filter supervisorSevenSessionSubprocessBenchmark
BANYAN_FIXTURE_DATA_HOME=/tmp/banyan-supervisor-bench/quiet-active/before \
  swift run --skip-build banyanctl perf report --since 1d --json
BANYAN_FIXTURE_DATA_HOME=/tmp/banyan-supervisor-bench/quiet-active/after \
  swift run --skip-build banyanctl perf report --since 1d --json
swift test --filter 'supervisor|statusSynchronizer|cachedPane'
swift test
```

The benchmark creates seven sleep-backed panes on a unique private tmux socket
and cleans up only those panes. Agent identity and activity timestamps are
synthetic; list-panes, capture-pane, kernel process snapshots and classification
run for real. The clock advances through 180 virtual seconds. `before` models
the previous unconditional executing-session cadence, with the same batched
snapshot and capture cache; it is not a second build of the live application.
Every fixture timing sample is retained in separate databases, with aggregate
reports and operation counts in the requested directory. Rerun into a fresh
directory to avoid accumulating earlier samples.

## Measurement, 2026-10-07

Local production telemetry was read before implementation. The 1-day report
retained 29 slow `supervisor.tick` events: p50 365.19 ms, p95 3599.80 ms, max
4079.36 ms; and 46 slow `supervisor.session` events: p50 266.17 ms, p95 1139.80
ms, max 2076.21 ms. These percentiles describe **retained slow events**, not all
ticks or sessions. Private event details are not included here.

The isolated before/after reports above produced the following full-sample
fixture distributions, in milliseconds (p50 / p95 / max):

| Scenario | Metric | Before | After |
| --- | --- | --- | --- |
| Quiet active | supervisor.tick | 8.082 / 8.775 / 15.336 | 8.010 / 15.881 / 15.881 |
| Quiet active | supervisor.session | 0.078 / 0.103 / 7.822 | 0.088 / 7.346 / 7.643 |
| Quiet hidden | supervisor.tick | 8.466 / 16.144 / 16.144 | 8.237 / 16.005 / 16.005 |
| Quiet hidden | supervisor.session | 0.087 / 7.967 / 8.083 | 0.106 / 7.726 / 7.751 |
| Output every tick | supervisor.tick | 15.894 / 17.006 / 17.591 | 15.932 / 17.008 / 17.806 |
| Output every tick | supervisor.session | 7.421 / 8.239 / 8.991 | 7.396 / 8.197 / 8.675 |

| Scenario | Scheduled ticks / list-panes | Process snapshots | Classifications | Captures |
| --- | --- | --- | --- | --- |
| Quiet active | 90 → 13 | 90 → 10 | 630 → 70 | 7 → 7 |
| Quiet hidden | 6 → 6 | 6 → 5 | 42 → 35 | 7 → 7 |
| Output every tick | 90 → 90 | 90 → 90 | 630 → 630 | 630 → 630 |

Quiet active work reduces tmux subprocesses from 97 to 20 and scheduled tick
wakeups by 85.6%. Hidden activity probes deliberately retain their cadence;
classification backs off to every other probe after the fast/startup phase.
Darwin process snapshots use kernel APIs, not `ps` subprocesses. Capture counts
were already low for unchanged panes and remain so. The after population loses
many cheap cached classifications, so its p95 can increase while total work
falls. Continuous activity keeps every session responsive, with fixture ticks
comfortably below the two-second base cadence.

Regression tests also cover a seven-second tick with a two-second cadence:
overlapping requests are rejected and the next scheduled tick starts no earlier
than two seconds after completion. Hidden need-input transitions are detected
by the next 30-second probe without PTY callbacks; silent child completion wakes
a deferred observation. A disposable child EOF test verifies the actual Darwin
exit event, shared-PID routing, and removal of suspended/removed watches.

These measurements count scheduled supervisor wakeups, not physical macOS CPU
wakeups. The live app was not restarted or changed. Post-merge verification
still needs comparable seven-agent live workload captures: run `banyanctl perf
report --since 1d --json`, retain the slow-sample caveat, and compare tmux/`ps`
subprocess counts, CPU wakeups and hidden CPU using the same workload and
duration. Verify selected attached and cache-evicted hidden completion/attention
latency, and preserve any opt-in process-freeze exclusions and wakeup hooks when
integrating other supervisor changes.

## Isolated post-merge runtime check

Run this macOS test alone from the merged checkout, using a fresh directory:

```sh
BANYAN_SUPERVISOR_RUNTIME_DIR=/tmp/banyan-supervisor-runtime \
  swift test --filter supervisorSevenHiddenSessionRuntimeFixture
cat /tmp/banyan-supervisor-runtime/latency.json
BANYAN_FIXTURE_DATA_HOME=/tmp/banyan-supervisor-runtime/data \
  swift run --skip-build banyanctl perf report --since 1d --json
```

Allow about three minutes. This uses actual `SessionStore` timers, real process
snapshots, real pane text/activity and seven executing terminal sessions. The
shell-agent scripts run locally without a subscription or model API. The test
process remains windowless and creates no control server. Its private HOME,
database and unique tmux socket are injected explicitly; it neither launches
nor restarts the installed Banyan app. It cleans up only its own sessions.
Setting a fixture data directory alone does **not** isolate an ordinary app's
default tmux socket; use this fixture instead of launching an extra app against
the live server.

After 105 seconds of quiet hidden execution, it checks an unattached attention
transition through tmux activity, a silent external child's completion through
the kernel exit event, a selected attached session, and the same selected
session after actual terminal-view eviction. Bounds are 42 seconds for the
hidden activity path (30-second probe plus timer tolerance/inspection allowance)
and six seconds for selected-output and exit-event paths. It writes measured
latencies and process snapshot count to `latency.json`. The ordinary tests use
a virtual clock to assert the stricter scheduling intervals without wall-clock
flakiness. The fixture's performance report retains the production slow-event
filter, so a fast run may contain no supervisor timing events.

For physical CPU wakeups and subprocess/CPU accounting, capture the isolated
test PID with Instruments Energy Log/System Trace for the same quiet and output
phases in each build. Keep those raw captures local, and report aggregate counts
with workload, duration, power/thermal state and attachment state. The fixture's
short latency waits are test-process wakeups; distinguish them from supervisor
timer firings. Swift Testing does not run `NSApplication.run()`, so the fixture
also services its own Foundation run loop once per second during warmup and
during latency waits. Repeat after integrating process freezing with freezing
disabled and enabled, confirming frozen rows are excluded and reconcile/unfreeze
events wake observation without restoring a repeating catch-up timer.
