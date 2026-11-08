# PuckSwift

A typed Swift client for Puck's session runtime. The client depends only on
Foundation and platform sockets, and has no Banyan dependency.

```swift
import PuckSwift

let client = PuckClient(socketPath: "/absolute/puck-home/daemon/puck.sock")
let capabilities = try await client.capabilities()
var options = PuckSessionOptions(workspace: "/absolute/workspace")
options.account = "work"
let session = try await client.create(options)
let page = try await client.history(session.id, limit: 50)
```

Create the follow stream before starting a turn to observe live events. Route
pending approvals/questions through your application's UI. Cancelling a follow
stream detaches that client; turn cancellation is an explicit `cancel` operation.
Errors preserve structured server codes. Request work and live buffers are
bounded; a lagged consumer reconnects and refreshes paged history.

`PuckHistoryWindow` provides a bounded, stable-ID display window. The embedding
application owns its global cache budget. Engine history remains authoritative;
legacy sessions may expose a labeled compatibility projection. Large display
items explicitly report truncation.

Since protocol 2.2, a native tool call and its output are separate
`tool_call` and `tool_result` items; pair them by `callID`. A `tool` item holds
a whole activity, such as a Codex command, with its output in `text`. Tool
items carry `toolName` and the raw call input in `arguments` when known; a Codex
command uses `exec_command` arguments, `{"cmd", "workdir"}`.

A turn may attach local images with `turn(_:prompt:images:)`; puckd copies
each one into its own store before the engine reads it. Check
`PuckCapabilities.acceptsImages(engine:)` first: a daemon without the
`turn_images` feature ignores the parameter. `decide(_:callID:decision:reason:)`
passes a denial's reason to engines that show it to the model.

Live progress arrives as transient events that the finished item or paged
history supersedes: `reasoning_delta` (then a journaled `reasoning` with the
same `itemID`) and `tool_output_delta` for a running command's `callID`.
History `user` items list their attached images in `images`, and `reasoning`
items carry a summary.

Run `swift test` or `swift run puck-swift-example /path/to/puck.sock` from this
package. The Puck repository root also exposes this package for SwiftPM Git
revision dependencies. See `docs/design/sdk.md` in the Puck repository for the
protocol, lifecycle, integration and resource contracts.

`PuckSessionSummary.presentation` provides task/attempt or job/run ownership,
work titles and separate attention reasons. A nil presentation indicates an
older daemon; a present presentation with a nil owner indicates an unmapped or
standalone session. `agentClass` and parent/subagent fields remain separate.
Use owner task/run IDs to fetch detailed blocker/error context on demand.

Use `PuckDaemonClient.watch()` for live session catalogs: task/job events refresh
ownership and attention even when no session turn occurs. Single-session follow
streams retain session events only. Membership and grouping remain client-owned;
idle history and execution failures are not automatically human-input requests.

In configured single-operator mode, CLI/desktop approval attempts are directed
to the operator's Puck DM; an ordinary socket does not prove human consent.
