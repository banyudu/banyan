# CPU scheduling for session processes

A recurring report is that agent work started from a Banyan session runs slower
than identical work started from Terminal.app, and that `ps` proves it: the
Banyan-side processes show `ni 5` / `pri 29` where the Terminal.app-side ones
show `ni 0` / `pri 31`.

Both halves of that are measurable, and neither is Banyan. This note records
what the numbers actually say, because the claim is easy to re-derive wrongly
and the wrong fixes (renicing session trees, raising QoS on spawn, moving the
tmux server out of the app's process tree) all cost real complexity and buy
nothing.

Re-measure with `scripts/scheduling-ab.sh`, run from inside a Banyan pane.

## `nice +5` is zsh, and it is not a slowdown

zsh's `BG_NICE` option nices every `&` background job by +5. It is on by default
in zsh 5.9 in every mode — non-interactive, login, and interactive alike — so a
user `.zshrc` that never mentions it does not turn it off.

It applies identically under Terminal.app. The same probe, run both ways:

| Host | foreground job | `&` background job |
| --- | --- | --- |
| Banyan pane | `ni 0` | `ni 5` |
| Terminal.app | `ni 0` | `ni 5` |

So an A/B that backgrounds the Banyan-side probes with `&` and runs the
Terminal.app-side ones in the foreground is measuring the shell, not the host.
That is the usual shape of the report, because a human in Terminal.app types
foreground commands while an agent in a pane backgrounds them.

The increment is relative, so it compounds through nested shells — a job
backgrounded by a shell that was itself backgrounded lands at `ni 10`, then
`ni 15`. Worth knowing, but it does not matter here, because:

**`nice` buys nothing on this scheduler.** Eight probes at `nice 0` against
eight at `nice 5`, started together on a saturated 16-core M3 Max:

| arm | probes | aggregate cores | total CPU-seconds |
| --- | --- | --- | --- |
| `nice 0` | 8 | 4.11 | 49.3 |
| `nice 5` | 8 | 4.11 | 49.3 |

Identical, to two decimal places, on the one axis the report says nice governs.
Whatever weight this scheduler gives BSD nice, it is small enough not to show up
at a 5-point difference under saturation, so `ni 5` is close to cosmetic here.
Chasing it is wasted work — and note that an unprivileged process cannot lower
its own nice again anyway, since only root may decrease it.

## macOS grants CPU to process trees, not to processes

The throughput gap behind the report is real, and it survives holding nice
still. Twelve probes per arm, all at `nice 0`, started at the same instant:

| arm | probes | aggregate cores | cores/probe | Miters/CPU-sec |
| --- | --- | --- | --- | --- |
| Banyan pane | 12 | 1.77 | 0.147 | 1.24 |
| Terminal.app | 12 | 10.23 | 0.852 | 1.07 |

A 5.8x gap. Three controls narrow what it can be:

- **Not core placement.** Throughput per CPU-second matches across arms, so both
  arms ran on comparable cores. The Banyan arm was denied CPU *time*; it was not
  parked on efficiency cores.
- **Not frontmost-app boost.** Repeating it with Banyan frontmost and Terminal
  launched via `open -g` (background) gives 0.164 vs 0.836 — unchanged. Which
  app the user is looking at does not decide this.
- **Not an intrinsic cap on the Banyan tree.** The same twelve probes with no
  competing arm get 8.67 aggregate cores (0.723 each). The tree can use the
  machine perfectly well when nothing else is asking.

What is left is load, and the way it lands says macOS apportions CPU between
*process trees*, then splits each tree's share among everything runnable inside
it. (Behaviourally, from the numbers below — the kernel's own grouping is behind
private interfaces that need root to read.) The Banyan tree in these
runs was already carrying a fleet of live agent sessions; the Terminal.app tree
was carrying nothing. Give the Terminal.app arm the same company — 25 extra busy
threads in its own tree — and it collapses the same way:

| arm | probes | aggregate cores | cores/probe |
| --- | --- | --- | --- |
| Banyan pane | 12 | 2.86 | 0.238 |
| Terminal.app + 25 busy threads | 12 | 2.98 | 0.248 |

The gap falls from 5.8x to 1.04x — the two arms land on top of each other, with
the filler thread count picked as a round number rather than fitted. Terminal.app
is not scheduled better than Banyan. It was idle.

## What this means

Sub-linear scaling with session count is the machine, not a policy Banyan can
opt out of. Thirty concurrent agents on sixteen cores is oversubscription, and
at the load averages these reports are filed at (300+) every tree on the system
is starved. The levers that matter are the ones that reduce concurrent runnable
work — parking sessions (`banyanctl suspend`, or Suspend in the sidebar) is the
direct one, and it is why parked sessions also drop out of the supervisor tick.

The levers that do not matter, and should not be added:

- Renicing session trees. Nice is inert here, and cannot be lowered unprivileged.
- Raising spawn QoS. Probes in both trees already report `USER_INTERACTIVE`.
- Re-rooting the tmux server outside the app's tree. Its share tracks the work
  inside it, not which app it hangs off; and the server is already orphaned to
  launchd (`ppid 1`) after tmux daemonizes, with no observable benefit.

For the related question of which process tree Activity Monitor charges energy
to, see [energy-impact.md](energy-impact.md).
