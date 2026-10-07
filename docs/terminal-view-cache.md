# Terminal view cache

The display client and the backing session have different lifetimes. Detaching a
hidden PTY client stops parsing output, but does not release the switcher's
container or the session's SwiftTerm view, buffers, and drawing resources.

The switcher now retains four terminal views, including the selected terminal,
in least-recently-selected order. `terminalViewCacheLimit` is injectable and has
a minimum of two: a deferred project switch must keep its source visible while
preparing its target. Both are protected until completion or cancellation.
Eviction cancels container callbacks, removes its hierarchy and cache entry,
terminates only the attach client, and clears the session's loaded view on the
main actor. Generation and source checks reject stale attachment completions,
refreshes, recovery callbacks, and delegate events.

Revisiting recreates the terminal and uses the inactive-client attach and
initial-screen synchronization paths. tmux owns the live pane and scrollback,
including copy-mode position; the agent and observed status remain intact.
Child termination continues through SwiftTerm's existing independent reaper.

The alternatives considered were releasing every hidden view immediately, or
retaining all views and only detaching their clients. The first adds allocation
and attachment work to every switch; the second leaves memory unbounded. A small
working set preserves fast cached switches while bounding terminal allocations.
The existing delayed client detachment remains for retained inactive views.

Measurements also exposed a SwiftTerm reset retention cycle:
`Terminal -> normalBuffer -> scroll bound method -> Terminal`. The reset callback
now captures the terminal weakly, matching construction. Without this fix,
repeated eviction/revisit releases views but leaks their terminal buffers.

## Reproduce the isolated measurement

On macOS with tmux installed, from the issue checkout:

```sh
swift test --filter TerminalViewCacheTests
python3 scripts/terminal-cache-bench.py --cache-limit 24 --output /tmp/terminal-cache-before
python3 scripts/terminal-cache-bench.py --output /tmp/terminal-cache-after
```

Use fresh output directories for each run. The driver creates 24 live private
fixture sessions, visits all of them three times, and samples the test process
with `heap --noContent -s` and `vmmap -summary` after each cycle. Each fixture
prints 1,500 numbered lines and keeps a `cat` process alive. It uses a unique
tmux socket, temporary HOME, isolated data directory, and a 1000-by-700 window.
Its sessions and clients are removed on normal completion. The test is opt-in;
the normal suite exercises eviction/revisit without heap inspection.

The 24-slot run reproduces retaining every visited fixture; both runs use the
same binary and differ only in cache capacity. An earlier run against the
original unbounded implementation also retained 24 views, 26,040 buffer
allocations, and approximately 137 MB of physical footprint.

The driver saves the equivalent of this read-only report as `perf.json`:

```sh
BANYAN_FIXTURE_DATA_HOME=/tmp/terminal-cache-after/data \
  dist/bin/banyanctl perf report --since 1d --json
```

By default it locates the local Swift build's CLI. `--banyanctl PATH` selects
another build, such as the main checkout's `dist/bin/banyanctl`. Keep raw
heap/vmmap and telemetry artifacts local; share only aggregate fixture results.

## Recorded fixture results

2026-10-07, Apple Silicon, macOS 27.2, debug build, CoreGraphics renderer:

| Metric | Retain 24 | Retain 4 |
| --- | --- | --- |
| Loaded views and containers, all three cycles | 24 | 4 |
| Live SwiftTerm terminal models, all three cycles | 24 | 4 |
| `BufferLine.data` allocations, all three cycles | 26,040 | 4,340 |
| `BufferLine.data` bytes | 79,921,536 | 13,320,256 |
| Physical footprint, cycles 1 / 2 / 3 (MB) | 138.2 / 137.4 / 137.4 | 61.9 / 62.0 / 62.0 |
| Peak physical footprint (MB) | 158.1 | 82.1 |
| Resident IOSurface, all three cycles (MB) | 20.0 | 20.0 |

The bounded run reduced buffer allocations by 83% and physical footprint by
approximately 55%, then plateaued across repeated switching. Resident IOSurface
usage stayed constant for this single-window fixture. A reduction in production
IOSurface usage is **not established** by this workload and remains a live
verification requirement.

The isolated one-day performance reports recorded:

| Metric | Retain 24: count, p50 / p95 (ms) | Retain 4: count, p50 / p95 (ms) |
| --- | --- | --- |
| `terminal.start_client` | 24, 90.05 / 119.99 | 24, 75.83 / 81.44 |
| `session_switch.to_terminal_ready` and `.total` | 24, 20.87 / 22.20 | 72, 19.96 / 23.62 |
| `session_switch.to_first_output` | 24, 141.61 / 168.59 | 72, 30.10 / 134.57 |
| `terminal.inactive_reattach` | none | 48, 3.09 / 4.50 |

Cached quiet revisits do not generate another ready callback or new output,
whereas evicted revisits do. These distributions therefore have different
sample populations; they document attachment cost, not a universal switch-speed
improvement. Production agent workloads and visible synchronization still need
the supervisor's runtime check.

## Regression coverage

`TerminalViewCacheTests` checks 24 live sessions across repeated visits, actual
terminal-model release, attach-child collection without calling `waitpid`, LRU
ordering and capacity changes, deferred project-switch pressure/cancellation,
pending-ready cancellation, stale delegate notifications, and delayed attach
success/failure after unload. A live-pane revisit checks root PID, visible
content, tmux copy-mode scrollback, terminal input, and status/tone preservation.
The existing geometry test observes layout completion instead of racing its
main-queue synchronizer against a short polling deadline.
