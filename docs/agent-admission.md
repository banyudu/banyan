# Concurrent agent admission

Banyan defaults to four concurrent agent slots. Set **Preferences → Sessions →
Concurrent agent slots**, or use `banyanctl agent queue limit 4` (range 1–64).
The setting applies to new admissions immediately. Lowering it never stops,
renices, moves, or terminates running work.

The corrected scheduling investigation found oversubscription, rather than a
Banyan-specific nice or QoS penalty. Parking reduces frontend work but leaves
agents alive. Admission reduces additional demand by delaying new work.

## What consumes a slot

| Runtime | Slot lifetime |
| --- | --- |
| Terminal | From reservation before launching a nonempty configured command until confirmed CLI job/provider exit. This deliberately includes custom agent wrappers, idle CLIs, pending approvals, parked rows, and SIGSTOP-frozen agents. |
| Native Codex | Each active thread/turn, including pending approvals and user-input requests. Create, resume, recovery, and turn-start RPCs reserve provisionally until an authoritative idle state is established. |
| Puck | Each active or approval-blocked turn started through Banyan. The reservation includes the turn RPC and subsequent reconciliation. |
| Plain shell | No slot for opening the shell. |

A native shared server can execute several turns in parallel; every active
thread consumes its own slot. Idle native conversations do not consume a turn
slot. The shared idle server, stored thread metadata, native idle caches, tmux,
and shell processes are baseline resources outside this work budget. This is
not a hard CPU, memory, OS thread, individual subprocess, or machine-wide limit.
One CLI agent may spawn several tools/subagents within its slot.

App launchers, custom session commands, `banyanctl spawn`, `session new`,
`agent run`, restored missing-session recovery, restart, CLI fallback, and native
Codex creation/start/resume/recovery use the same controller. Same-pane deep
resume reserves before journal update/injection, including focus/input recovery. Existing work
restored above the cap keeps running; no new work is admitted until the count
falls below the configured limit.

Commands typed manually into a shell, standalone coding agents, independent
Puck daemon clients, and other external frontends can start work outside
Banyan's admission authority. Built-in `banyanctl puck new --prompt`, `turn`,
interactive attach, and TUI sends consult the app when reachable. They fail
before queuing when full, with retry/app-queue guidance. Connection refusal
allows existing offline daemon delivery; HTTP errors/timeouts never fall back.
Offline daemon work has no app budget and is adopted on reconnect. Observed external
native/Puck work is counted without preemption, which can take the count above
the cap and blocks additional managed starts. This policy does not promise to
stop arbitrary processes launched outside its managed entry points.

## Queue behavior

Queued rows remain visible and selectable, with their position and used slots
shown in the detail banner. Selecting a row never preempts another agent or
changes FIFO order. **Run Next** explicitly moves it to the front; **Cancel
Queued Work** prevents an unstarted launch/turn. Neither action stops running
work. **Queue Again** retries a cancelled terminal launch. Capacity released
later starts the next row without stealing the user's current selection.

```sh
banyanctl agent queue
banyanctl agent queue prioritize session-id
banyanctl agent queue cancel session-id
banyanctl agent queue retry session-id
banyanctl agent queue limit 4
```

`GET /agent-queue` reports `limit`, `running`, and FIFO `queued` IDs. Session
summaries expose `agentQueuePosition`, `agentLaunchCancelled`, and
`usesAgentSlot`. `POST /agent-queue` takes `id` and `detail` (`prioritize`,
`cancel`, `retry`); `POST /agent-limit` takes `limit`. Existing control-token
protection applies.

Synchronous control sends never wait in the admission queue: a busy response
means no prompt was queued. Short request deadlines prevent delayed daemon
lookups/creation from starting stale prompts. If delivery was already sent to
the daemon and its response is lost, inspect the session before retrying.

Terminal launch intent and cancellation persist in SQLite, including FIFO
request timestamps and whether the queued operation is launch, restart, or deep resume. On restart, the complete live fleet is accounted for before
any queued launch or recovery can acquire capacity. Native/Puck queued sends
are in-memory operations: cancellation preserves conversation identity,
settings, approvals, and the composer's draft. They are never automatically
replayed after an app restart, when delivery could be ambiguous.

## Exit, uncertainty, and deep suspension

Status labels, display detachment, parking, freezing, an interrupt ACK, and a
journal's optimistic suspended/terminating state cannot prove process exit.
Failed process inspection or tmux lookup retains the slot and offers **Recheck**.
A successful launch without a captured process cannot be optimistically freed
because a later lookup returns nil. Definitively failed creation with verified
pane absence can release an unused reservation. Native/Puck timeouts retain
capacity until reconnect/watch reconciliation establishes the outcome.

The main-actor integration surface for deep suspension is:

```swift
store.recordAgentProviderIdentity(id: id, identity: providerIdentity)
// Terminate and confirm actual provider/tree exit, keeping the pane if needed.
store.confirmAgentProviderExit(id: id, identity: providerIdentity)
// Before same-pane restart/injection, including focus and input recovery:
guard store.requestAgentAdmission(id: id, retry: retryDeepResume) else { return }
// Begin the admitted deep resume.
```

The persistent host keeps an outer pane host/login shell after ordinary `/quit`.
Its inner command host waits for the CLI job and exits after it, so admission
records that separate job identity during a bounded startup handshake and watches
its exit. Deep suspension records the verified provider identity before TERM.
Provider/job identities persist independently of pane roots: focusing/attaching
a surviving plain shell does not reacquire a slot; explicit restart does.
Uncaptured or unreadable startup remains reserved rather than inferring exit
from an empty process list. There is no repeating process poll.

Exit callbacks must match the recorded kernel start identity. Confirming exit
rechecks BSD process identity/zombie state and rejects unknown or still-live
processes. A generation-bound kernel exit event also establishes exit when a
zombie is not yet reapable/inspectable. A stale
callback cannot release a newer provider's reservation. Queue callbacks and
process probes are generation-bound. Restored terminating/resuming/unknown
journals retain capacity; optimistic `isDeepSuspended` alone never releases it.
Synchronous input refuses a busy or terminating resume without enqueuing a
prompt or resume retry. The admission controller also works when
deep suspension is unavailable; it is not a hidden prerequisite.

Puck resource accounting uses the shared dashboard watch rather than transcript
following. Hidden and removed rows remain accounted for until completion. A
turn finishing before its RPC reply is reconciled after the reply, with pending
approvals and unknown states retaining capacity.

## Validation

Deterministic tests cover FIFO release, explicit priority, concurrent claims,
deduplication, cancellation after grant, over-cap adoption, persistence,
foreground selection, parked/frozen CLI accounting, failed/denied inspection,
CLI launch failure, close/launch races, and native parallel turns/approvals.
Private runtime tests also cover ordinary exit with a surviving shell, delayed
TERM, deep-resume queue/cancellation/restoration, uncertain resumed startup,
actual CLI input while full, and native-to-CLI ownership transfer with late
native events/defers.

```sh
swift test --jobs 4 --filter AgentAdmission
BANYAN_RUN_ADMISSION_INTEGRATION=1 swift test --jobs 4 --filter AgentAdmissionIntegrationTests
```

The opt-in runtime suite uses UUID tmux sockets, a private database/home, and
synthetic agents. It checks actual process overlap, the sum of per-process
start-sampled high-water RSS, live Python thread counts measured behind a start
gate, CPU time, restoration, and provider exit with a preserved parent pane. It never
signals a live user or worker session. Its fleet report is diagnostic evidence,
not a promise of a particular throughput improvement on an oversubscribed host.
