# Codex App Server topology and memory spike

Status: completed on 2026-09-23 with `codex-cli 0.146.0` on macOS 27.2 arm64
(48 GiB RAM). This spike adds no production session-path changes.

## Recommendation: proceed, with an adjustment

Use **one Banyan-owned stdio App Server child per running Banyan process** for
the first native client. Do not make the managed daemon or a dedicated Unix
socket the default transport yet.

The underlying cause of the topology question is twofold:

- A separate Codex TUI has a substantial fixed process cost per session.
- Loaded App Server threads are retained for 30 minutes after their last
  subscriber disconnects, so a shared server's memory is not immediately
  reclaimed.

The stdio child gives Banyan exclusive lifecycle ownership, straightforward
crash detection, and a JSONL transport. A dedicated Unix socket uses a
WebSocket upgrade protocol, needs another connection/reconnect layer, and
creates lifetime/version coordination with other Codex front ends. Its main
benefit is cross-process sharing, which Banyan does not need for the initial
native client.

Persist the thread id **and its cwd, model, approval policy, and sandbox
settings**. On a child restart, start a new child and call `thread/resume` with
those settings explicitly. In this build, `thread/resume` restored the cwd but
returned the current default approval policy (`never`) rather than the
thread's initial `untrusted` setting. A thread with no completed turn also had
no rollout to resume.

The memory result is not a compelling reason by itself to migrate: the shared
server was larger at one and two idle threads and only approximately tied at
four. The reason to proceed is the direct control of thread lifecycle,
approvals, and streaming; memory savings are a possible higher-concurrency
benefit that needs repeated release-build measurements.

## Process topology

```
Banyan native client
  └─ codex app-server --listen stdio://        one owned child
       ├─ thread A: cwd A, untrusted + workspace-write
       ├─ thread B: cwd B, never + read-only
       └─ thread N: independent persisted history and event subscription
```

The App Server protocol is bidirectional JSON-RPC. Stdio uses newline-delimited
JSON; a custom Unix endpoint uses a WebSocket connection over the socket. The
[official App Server documentation](https://developers.openai.com/codex/app-server)
describes the initialization handshake, `thread/start`/`thread/resume`, event
streaming, and the available transports.

I also started `codex app-server --listen unix://<temporary-socket>` and
attached `codex --remote unix://<temporary-socket>` while a direct CLI TUI was
running. The private socket was created and both clients started without a
listener error. This is basic CLI coexistence, not a claim that a single
shared daemon should be used by Banyan and every other Codex front end.

The npm-distributed CLI used for this spike could not start the managed
`codex remote-control` daemon: it requires the standalone installation managed
by the Codex installer. Therefore managed-daemon/Desktop coexistence remains a
packaging-specific manual check for the standalone build; Banyan must not make
it a prerequisite.

## Commands and configuration

The committed probe is manual and requires an already authenticated `codex`:

```sh
node scripts/codex-app-server-spike.mjs \
  --thread-counts 1,2,4 \
  --output /tmp/codex-app-server-spike.json

node scripts/codex-app-server-spike.mjs \
  --idle-unload \
  --output /tmp/codex-app-server-idle-unload.json

codex app-server generate-ts --experimental --out /tmp/codex-app-server-schema
codex app-server --listen unix:///tmp/banyan-codex-app-server.sock
codex --remote unix:///tmp/banyan-codex-app-server.sock
```

The functional run used one stdio child and four temporary working directories.
Thread 1 used `approvalPolicy: "untrusted"` and `sandbox: "workspace-write"`;
the other threads used `approvalPolicy: "never"` and `sandbox: "read-only"`.
The probe accepts only the exact, temporary proof-file command and declines any
other command approval request.
The probe verifies the current *wire* values. The same server returns the
legacy result spelling (`workspaceWrite`/`readOnly`), so clients must generate
types from the exact Codex binary they invoke rather than copying field values
from a different release.

The command generator is version-specific by design, as noted in the
[official schema guidance](https://developers.openai.com/codex/app-server).

## Lifecycle results

| Operation | Result |
| --- | --- |
| Start four threads with separate cwd/settings | Passed; `thread/loaded/list` contained all four. |
| Stream a turn | Passed; `item/agentMessage/delta` preceded `turn/completed`. |
| Independent second thread | Passed; it completed a separate turn in its own cwd. |
| Command approval | Passed; server sent `item/commandExecution/requestApproval`; replying `{ "decision": "accept" }` allowed a proof-file write. |
| Unsubscribe | Passed; `thread/unsubscribe` returned `unsubscribed`. The thread remained loaded immediately after, as expected. |
| Idle unload | Passed; after the last unsubscribe the server emitted `thread/closed` after 30 minutes and 4 seconds. |
| Restart recovery | Passed for threads with a completed turn: a replacement server resumed both persisted thread ids. |

The observed 30-minute delay matches the documented no-subscriber inactivity
grace period. Use `thread/closed` (and the preceding `notLoaded` status change)
as the client-side signal to release view state; do not assume unsubscribe
immediately frees server memory.

## RSS sample

Each number is one `ps` RSS sample in KiB, summing only the process tree
started by the probe. App Server measurements were taken after `thread/start`
and `thread/loaded/list`, with no active turns. TUI measurements used the same
number of independently started interactive Codex terminal UIs under a PTY.

| Idle session count | Shared App Server RSS | Per-session TUI RSS | App Server minus TUI |
| ---: | ---: | ---: | ---: |
| 0 | 150,432 KiB | — | — |
| 1 | 234,688 KiB | 100,272 KiB | +134,416 KiB |
| 2 | 252,096 KiB | 200,944 KiB | +51,152 KiB |
| 4 | 394,912 KiB | 401,808 KiB | -6,896 KiB |

RSS is a process-resident sample, not a unique-physical-memory measure: it can
double-count shared pages and varies with caches and the current CLI build.
Treat the four-thread difference (about 7 MiB) as parity, not a reliable
memory win. Re-run the probe on supported release builds before setting a
session-count threshold.

## Protocol maturity and compatibility

Core methods used here are documented: `initialize`, `thread/start`,
`thread/resume`, `turn/start`, streamed item/turn notifications, approval
requests, `thread/unsubscribe`, and `thread/loaded/list`. However, the CLI
labels `app-server` experimental, and the official documentation says the
app-server command and WebSocket transport are not supported for production
workloads. Pin the Codex CLI version, generate the protocol schema during
integration testing, and fail closed on an incompatible handshake or method.

The native Banyan baseline does **not** require an experimental API method.
The following features should remain out of the first implementation unless
the client opts into `capabilities.experimentalApi` and version-gates them:

- `thread/turns/list` and `thread/items/list` for paginated historical
  transcript hydration.
- `dynamicTools` on `thread/start` for client-defined tools.
- `thread/backgroundTerminals/*`, `process/*`, and `environment/info`.
- Named permission profiles and related fields that are currently beta.

`thread/read` can cover a small initial history view without those paginated
experimental endpoints. The server rejects experimental methods or fields
unless the client explicitly opts in, so there is a clean baseline/advanced
feature boundary.

## Follow-up constraints

- Keep the existing terminal session path unchanged during this spike.
- Feature-gate any native client behind an explicit preference while App Server
  remains experimental.
- Resume with persisted settings; retry by restarting Banyan's own child, not
  by attaching to an arbitrary external daemon.
- Treat no-turn threads as non-resumable until the server persists a rollout;
  retain enough UI metadata to explain that state.
