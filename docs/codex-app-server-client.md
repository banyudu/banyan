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
`initialized`. Banyan accepts the tested Codex CLI `0.146.x` family and exact
`0.160.0` release from the server's user-agent prefix. An unknown format or version fails
closed with an actionable error; the CLI/tmux fallback remains available.
Expand the accepted versions only after testing that version's generated schema
and the transport tests. `0.160.1` and other untested releases remain gated. This check is deliberately inside the Codex adapter.

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
in the macOS app and `CodexThreadCoordinator` in BanyanCore. Native Codex is
**off by default** during rollout. In **Preferences → Codex**, enable **Enable
native Codex client (preview)**, then choose **Codex (Native)** in the
new-session sheet. The standard **Codex** launch profile, `banyanctl agent run
--agent codex`, and **Terminal** with command `codex` use the interactive CLI.
Existing CLI sessions keep their launch/resume behavior.

**Enable Codex remote-control TUI** is a separate preference for the older
interactive TUI/remote-control workflow. It does not enable the Banyan-owned
native client. Puck runtimes are independent of both preferences.

Disabling native Codex refuses new native sessions, connects, and turns. Idle
subscriptions release, including the selected thread. An entirely idle child
is stopped and reaped. Active turns and pending replies remain subscribed and
observable until completion; reading their history, answering requests, and
explicitly interrupting an existing turn remain available without starting a
new child. Completion releases the last subscription and child. Re-enabling
reconnects the selected thread by its saved ID. Other native rows reconnect on
selection; no new threads are created for mapped rows.

The underlying problem was missing session ownership above the transport:
terminal launch metadata could not identify or release a native subscription.
Keeping a child per session would repeat transport ownership and prevent shared
subscription accounting. Encoding native sessions as terminal commands would
also leave resume and approval state dependent on a TUI. The native backend
therefore persists a thread binding and delegates all lifecycle RPCs to one
coordinator over the existing app-owned client.

`SessionSnapshot.codex` and the additive SQLite `codex_binding` column retain
the thread ID, original Codex storage root, absolute working directory (including a worktree path), model,
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

## CLI fallback and failure cleanup

Use **Use Codex CLI** above a native conversation when server startup fails,
a required capability is unavailable, or the native UI does not support the
workflow you need. Handoff replaces the runtime on the same Banyan row. It
preserves its ID, title, parent, timestamps, thread ID, cwd, Codex storage root,
model/provider, approval policy, sandbox, and config overrides. The storage
root comes from the actual resolved child environment (or server-reported
`codexHome`), so shell-only `CODEX_HOME` settings are retained. Older bindings
learn it through the service; an unknown store prevents handoff. If a later
native launch uses a different store, Banyan refuses to resume there and offers
CLI handoff using the recorded original home. The terminal
runs `codex resume <exact-thread-id>` with the recorded settings. Closing,
reopening, recovering a missing tmux session, or restarting Banyan continues
that ID; the older remote-control preference cannot rewrite this command.
`banyanctl session list` reports native rows as `backend: "codex"`, terminal
fallback rows as `backend: "tmux"`, and includes their `codex` binding with
`cliFallbackReason` for fallback provenance.

Handoff waits for all native turns and pending requests to finish. Banyan then
stops and reaps its shared private server before allowing the CLI to acquire a
writer. It never kills a busy sibling thread just to hand off an idle one.
Other idle native sessions preserve their mappings and can reconnect later.
The native toggle may remain disabled while the fallback runs.

A startup compatibility failure is reported before any Banyan row is inserted;
the rejected child is reaped. Choose Terminal with command `codex`, or update
Banyan to a release tested with the installed CLI. A definite missing
`thread/start` method also removes the uncreated row. A lost or timed-out start
is different: it may have created a real thread, so the recovery row remains.
Use coordinator list/read and `recoverCreation` to choose that stored ID before
handoff. Banyan refuses to guess a thread or start a replacement. An empty
native thread may have no rollout until its first turn; CLI resume can report
that missing history while preserving the ID. A config override containing
`null` is refused because the CLI's TOML cannot represent it.

## Installed-Codex verification

Run the opt-in smoke test without touching live sessions:

```sh
BANYAN_TEST_INSTALLED_CODEX=1 swift test --filter installedCodexSchemaStartupAndExactThreadResume
```

It checks the installed `0.160.0` generated lifecycle schema and uses an empty,
temporary `HOME`/`CODEX_HOME` with a refused loopback inference endpoint. It
checks initialize, start, the expected offline failed turn, read, unsubscribe,
server reap/restart, exact-ID resume with settings, and CLI fallback argument
parsing. No credentials or live Codex/Banyan/tmux server are used. Fixture tests
cover unsupported versions, a child ignoring SIGTERM, capability failures,
uncertain starts, busy-thread refusal, rollout toggling, persistence, and
unified CLI output.

Live validation should use a tested `0.146.x` or `0.160.0` CLI. Verify a completed thread across an app/server restart,
pending approval while changing selection, and coexistence with an external
writer. The server's 30-minute unload grace and mobile handoff require live
checks; fast fixture tests prove client subscription decisions, not RSS savings
or external-client writer release.
