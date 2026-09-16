# Terminal renderer experiment: CoreGraphics vs Metal

SwiftTerm ships an experimental Metal renderer (`MetalTerminalRenderer`:
CoreText glyph atlas plus GPU quads) that is disabled by default. This
documents how Banyan opts into it, how the two renderers were compared, and
what the measurements said.

## Opting in

Preferences has a **Terminal renderer** picker. It writes the `terminalRenderer`
default and applies to live sessions immediately; sessions without a terminal
pick it up when one is created. `BANYAN_TERMINAL_RENDERER=metal|cg` pins a
renderer for one launch and wins over the stored preference, which is how a
benchmark arm is selected without disturbing the user's settings.

If the GPU path fails to start (no Metal device, pipeline compilation failure),
the view logs and stays on CoreGraphics; an experimental renderer must never
cost the user their terminal.

## What each renderer actually does

A terminal frame costs three things:

1. Building each dirty row's `ViewLineInfo` - attributes, implicit link
   detection, box-drawing and block-element extraction. CPU.
2. Turning that into pixels: CoreText runs and background fills into a
   `CGContext`, or glyph-atlas quads uploaded to the GPU.
3. The invalidation cadence, which decides how often 1 and 2 happen.

Metal only replaces step 2. Step 1 is identical work in both paths - and the
Metal path is currently at a structural disadvantage there:

- `MetalTerminalRenderer.buildRowDrawData` calls
  `terminalView.buildAttributedString(...)` directly, so it does not use the
  `lineInfoCache` that the CoreGraphics path consults.
- `CacheSignature` includes `yDisp`, so **any scroll discards the whole row
  cache** and every visible row is rebuilt. Streaming output scrolls on every
  line, which is the workload this experiment cares about.

Banyan's own invalidation coalescing (`DetectingLocalProcessTerminalView.setNeedsDisplay`)
only sees the CoreGraphics path: under Metal, SwiftTerm routes invalidation to
the `MTKView` instead, which coalesces at the display refresh rate.

## Method

`Sources/TerminalRenderBench` replays a fixed, seeded stream of agent-like
output - plain text, SGR colour runs, detectable URLs, box-drawing progress
bars, periodic full-screen repaints - into a real `TerminalView` in a real
window, and times every frame:

- CoreGraphics frames are timed in `draw(_:)`, exactly like Banyan's
  `terminal.draw` metric.
- Metal frames are timed through `TerminalView.onMetalFrameRendered`, a hook
  added for this experiment; it reports the CPU cost of
  `MetalTerminalRenderer.draw(in:)`. GPU execution is asynchronous and is not
  included in that number, which is why process-level CPU counters are reported
  alongside it.

The harness turns on the same link detection and highlighting Banyan uses, and
mirrors Banyan's adaptive invalidation coalescing so the CoreGraphics arm
measures what Banyan ships. Both arms replay byte-identical input from the same
seed, so each one performs the same amount of terminal work.

Two workloads:

- `stream` - scrolling agent output. The viewport moves on every line.
- `static` - alternate-screen repaints addressed in place, like a full-screen
  TUI. The viewport never moves, so a renderer that keys caches on the scroll
  offset keeps them.

Energy: Activity Monitor's Energy Impact is a rolling platform estimate that
cannot be read back programmatically, so each run reports the process counters
it is derived from - CPU time, cycles, instructions retired, and wakeups - from
`proc_pid_rusage`. CPU time is the dominant term for this workload.

    scripts/terminal-render-bench.sh --reps 3 --bytes 6291456 --rate 524288 --workload both

The harness needs a visible, unoccluded window, because a Metal drawable comes
from the window server. Do not use the machine while it runs.

## Results

Median of 3 repetitions per arm, arms interleaved, Apple silicon, 157x50 cells,
6 MB of output at 512 KB/s. `metal-perframe` is the Metal renderer in
`perFrameAggregated` buffering mode.

### stream - scrolling agent output

| arm | draw avg | draw p95 | draw p99 | frames | draw total | process CPU | cycles | wall |
|---|---|---|---|---|---|---|---|---|
| cg | 3.09 ms | 5.19 ms | 6.09 ms | 478 | 1472 ms | 2732 ms | 9.58 G | 11.91 s |
| metal | 4.83 ms | 6.89 ms | 7.81 ms | 500 | 2423 ms | 3011 ms | 10.68 G | 11.70 s |
| metal-perframe | 4.73 ms | 6.73 ms | 7.85 ms | 503 | 2379 ms | 2971 ms | 10.54 G | 11.66 s |

### static - in-place alternate-screen repaints

| arm | draw avg | draw p95 | draw p99 | frames | draw total | process CPU | cycles | wall |
|---|---|---|---|---|---|---|---|---|
| cg | 3.28 ms | 6.55 ms | 9.61 ms | 293 | 963 ms | 1810 ms | 6.01 G | 7.26 s |
| metal | 4.81 ms | 6.83 ms | 8.55 ms | 303 | 1456 ms | 1919 ms | 6.68 G | 7.09 s |
| metal-perframe | 4.53 ms | 6.35 ms | 7.16 ms | 304 | 1377 ms | 1842 ms | 6.51 G | 7.05 s |

Metal costs about 56% more per frame on streaming output and 47% more on
in-place repaints, and 10% more process CPU and 11% more cycles over the same
work. Its one advantage is consistency: on the static workload its p99 is better
than CoreGraphics' (8.55 ms vs 9.61 ms, and 7.16 ms in `perFrame` mode), and it
keeps up with the feed slightly better (500 frames vs 478 over a marginally
shorter wall time). It is steadier, and more expensive.

### Where the Metal frame goes

Instrumenting one Metal frame on the stream workload (temporary patch, not
committed):

    total 4.90 ms
      buildDrawData          4.72 ms
        line info            1.34 ms   attributes + implicit link detection
        glyph shaping        0.39 ms
        vertex + buffers     2.99 ms   per-cell quads, per-row MTLBuffers
      encode + present       0.18 ms

Two things follow. The GPU submission side is already cheap - the atlas and the
draw calls are not the problem. And the 2.99 ms is work CoreGraphics never does
at all: CoreText draws runs straight into the context, while Metal materialises
per-cell geometry on the CPU first. That cost is paid on nearly every frame
because the renderer's `rowCache` is keyed on a `CacheSignature` that includes
`yDisp`, so a single scrolled line discards every cached row.

Sharing the view's `lineInfoCache` with the Metal path was tried and reverted:
it moved the line-info term by 0.05 ms, because once the scrollback wraps, row
indices shift under the cache on every scroll and it stops hitting for either
renderer.


## Decision

**No-go for enabling Metal by default.** The opt-in stays, defaulting to
CoreGraphics.

The renderer is measurably worse on exactly the workload this app is built
around - streaming agent output - on both the metric the issue asked about
(`terminal.draw`) and the one behind Energy Impact (process CPU and cycles).
Nothing about the result is marginal enough to justify shipping it and watching.

Note that the CPU numbers understate the gap for energy purposes: they do not
include GPU package power, which only the Metal arm spends.

What would have to change before it is worth re-measuring:

1. **Row geometry must survive scrolling.** Vertex positions are baked in view
   coordinates and `CacheSignature` includes `yDisp`, so scrolling one line
   rebuilds every visible row. A per-row Y translation passed as a uniform would
   let `rowCache` survive a scroll, which is what turns the 2.99 ms per-frame
   vertex cost into "rebuild the rows that changed".
2. **Per-row buffer churn.** `makeRowBuffers` allocates MTLBuffers per row per
   rebuild; with (1) in place this becomes the next term to look at.

Until then the GPU path cannot beat CoreText for a terminal-sized grid on this
hardware, and the measurements should be repeated on an Intel Mac with a
discrete GPU before the conclusion is generalised beyond Apple silicon.

## Overlay behaviour under Metal

Found by audit while wiring the opt-in, and fixed here:

- The `MTKView` was inserted below the caret view but above every subview added
  earlier - the scroller and the progress bar. It now goes below all siblings,
  since the GPU surface is the terminal's background and everything else is an
  overlay on it.
- Link hover underlines are baked into a row's attributes, and hovering does not
  change the line's generation, so the cached row info survived the repaint that
  hover triggers. The cached row is now dropped. This affects CoreGraphics too.
- Host-side repaints (`needsDisplay = true`, `setNeedsDisplay(bounds)`) never
  reach the `MTKView`. Banyan's six force-a-repaint sites - reveal after
  initial-screen sync, reattach, theme change, geometry sync, window lifecycle,
  process reset - now call `TerminalView.requestFullRedraw()`. Without this a
  Metal session goes blank after a switch.

Verified by reading the code, not by running it:

- Caret: hidden as a view under Metal and drawn by the renderer, blink included.
- Selection: `selectionChanged` has a Metal branch, and drag extension notifies
  through `setActiveAndNotify`, so highlights repaint.
- Find bar and URL preview: created lazily, so they are added after the GPU
  surface and sit above it.
- Scrollback restore: `scrollTo` repaints through `updateDisplay`, which is
  Metal-aware.
- `VisualSnapshotter` captures with `CGWindowListCreateImage`, a window-server
  composite, which does include Metal content. Its `cacheDisplay` fallback does
  not, and would capture a blank terminal area.
- The `session_switch.to_terminal_ready` paint probe is a separate CoreGraphics
  view, so under Metal it no longer coincides with the terminal's own paint.

None of this was verified visually in the running app: capturing the screen is
not available to a CLI process here, and the decision above does not depend on
it. Anyone turning the picker on should re-check these by eye.

