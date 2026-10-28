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

Run `swift test` or `swift run puck-swift-example /path/to/puck.sock` from this
package. The Puck repository root also exposes this package for SwiftPM Git
revision dependencies. See `docs/design/sdk.md` in the Puck repository for the
protocol, lifecycle, integration and resource contracts.
