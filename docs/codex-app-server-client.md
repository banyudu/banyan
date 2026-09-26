# Banyan-owned Codex App Server client

The native Codex adapter is `CodexAppServerClient` in BanyanCore. The Banyan app
owns one client instance. It starts one child on the first native operation,
keeps the child for the app lifetime, and stops it before app termination. A
second operation joins an in-progress connection or reuses the ready one. A
server exit fails every pending operation, emits a disconnect event, and lets
the next operation start a fresh child. The higher-level thread layer must
resume its persisted thread IDs and settings after reconnecting.

## Endpoint and authentication

The child runs `codex app-server --listen stdio://`. Its JSONL endpoint is the
private stdin/stdout pipe pair inherited from Banyan, so it has no socket path
or port and cannot collide with the Codex Desktop managed server. Banyan never
attaches to `unix://` or starts `codex remote-control` for native operations.
The older opt-in terminal mode still uses remote-control and an interactive TUI;
the native session integration is tracked separately.

The child inherits the app's ordinary process environment and uses Codex's
supported login state. The adapter does not inspect, read, or copy Codex's
credential files. Authentication failures arrive as regular App Server errors
for the future session UI to explain.

## Protocol and compatibility

Each connection sends `initialize`, checks the returned `userAgent`, then sends
`initialized`. Banyan currently accepts the tested Codex CLI `0.146.x` protocol
family from the server's user-agent prefix. An unknown format or version fails
closed with an actionable error; the CLI/tmux fallback remains available.
Expand the accepted range only after testing that version's generated schema
and the transport tests. This check is deliberately inside the Codex adapter.

The adapter assigns monotonically increasing request IDs, routes responses by
ID, broadcasts notifications to event subscribers, and answers server-initiated
requests through a caller-provided handler. Without a handler, it returns the
JSON-RPC method-not-found error. One reader processes JSONL frames in order;
an 8 MiB message limit and per-request timeout bound a stalled connection.
Unknown notification methods and fields pass through as JSON values.
An event subscriber that falls more than 1,024 events behind is ended so it
cannot grow memory without bound; its owner should reload thread state before
subscribing again.

The App Server protocol and the `userAgent` field are described in the
[official OpenAI App Server documentation](https://developers.openai.com/codex/app-server).
