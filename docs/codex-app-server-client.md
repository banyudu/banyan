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

## Native sessions and subscription lifetime

The native backend is `SessionBackendKind.codex`, represented by `CodexSession`
in the macOS app and `CodexThreadCoordinator` in BanyanCore. Choose **Codex
(Native)** in the new-session sheet to opt into this backend. The existing
remote-control/TUI preference continues to describe terminal launches.

The underlying problem was missing session ownership above the transport:
terminal launch metadata could not identify or release a native subscription.
Keeping a child per session would repeat transport ownership and prevent shared
subscription accounting. Encoding native sessions as terminal commands would
also leave resume and approval state dependent on a TUI. The native backend
therefore persists a thread binding and delegates all lifecycle RPCs to one
coordinator over the existing app-owned client.

`SessionSnapshot.codex` and the additive SQLite `codex_binding` column retain
the thread ID, absolute working directory (including a worktree path), model,
provider, approval policy, sandbox mode, and config overrides. The effective
model/provider returned by the server are retained too. Selection uses
`thread/resume` with those settings. A missing rollout or active-writer error
never falls back to `thread/start`. A start whose result was lost remains an
unbound row marked `creationAttempted`; list/read can recover its identity
explicitly without sending a second start. The host drains queued SQLite writes
before sending a start and before returning the learned mapping. Removed or
pruned rows reserve their coordinator IDs until app exit, and conflicting
re-registration is rejected. Reusing a requested name allocates a fresh row
and thread. Permanent removal is rejected during active turns or pending
requests. Closing to history stays reopenable, and retention preserves native
rows; busy work remains observed until safe to detach.
Unsubscribed rows release their hydrated transcript from client memory.

The coordinator records selection intent before awaiting serialized lifecycle
RPCs. Only a confirmed idle thread without an active turn or pending server
request can unsubscribe. Active background turns remain subscribed, as do
approval and user-input waits. Completion/resolution notifications trigger the
idle release without a timer. An unsubscribe response marks the connection
unsubscribed; only server status/closed notifications mark it unloaded. An
active event arriving during unsubscribe triggers immediate resume. A failed
event stream or server exit makes runtime status unknown and exposes reconnect;
it does not describe the session as hibernated.

Writer conflicts retain both ID and cwd and tell the user to finish work or
exit/detach the other CLI/TUI before reconnecting. `thread/read` remains usable
without acquiring a subscription. Unsubscribe does **not** claim to release an
external writer immediately: the server owns its unload grace period.

## Consumer interface

- `SessionStore.createCodexSession(settings:cwd:id:title:parentSessionID:select:)`
  creates a native row and connects it. `.codex(settings)` is also a launch spec,
  so sibling sessions preserve per-thread settings.
- `CodexSession.state` publishes binding, connection, runtime status, active
  turn ID, pending requests, and subscription state. The initial detail view
  exposes lifecycle status and reconnect. Conversation rendering is separate.
- `CodexThreadCoordinator.select/connect/detach` manage subscriptions.
  `list(cursor:cwd:)` returns server pagination; `read(sessionID:includeTurns:)`
  hydrates history without subscribing. `onEvent` routes raw item/turn events
  by Banyan session ID; consumers should read history when attaching.
- `startTurn(sessionID:input:)`, `interrupt(sessionID:)`, and
  `respond(sessionID:requestID:reply:)` provide the conversation action boundary.
  Replies retain their pending marker until the server resolves them. A stale
  request cannot be answered after disconnect or resolution by another client.
- `recoverCreation(sessionID:threadID:)` binds an explicitly selected stored
  thread to an uncertain creation after verifying its cwd. It cannot replace
  an existing mapping or map the same thread into two rows.

The conversation UI and identity-preserving CLI handoff are follow-ups. Live
validation should use a tested `0.146.x` CLI: the transport deliberately rejects
other protocol families. Verify a completed thread across an app/server restart,
pending approval while changing selection, and coexistence with an external
writer. The server's 30-minute unload grace and mobile handoff require live
checks; fast fixture tests prove client subscription decisions, not RSS savings
or external-client writer release.
