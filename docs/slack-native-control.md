# Native Codex control from Slack

Banyan owns the App Server, session ID, thread ID, settings and pending requests.
Slack is an additional interface to an existing native session. The connector
runs on the Mac and uses outbound Socket Mode; no public endpoint is needed.
The Mac, Banyan and connector must remain running and awake. Terminal sessions,
new-session creation, DMs and other providers are outside this MVP.

## Design and ownership

The missing capability was independent observation and structured remote input,
not a missing Codex runtime. Terminal parsing cannot bind structured approvals
or turns reliably, and a connector-owned App Server would split conversation
ownership. `CodexRemoteControl` therefore wraps Banyan's existing coordinator.
Its observer registry preserves desktop callbacks. Attachment generations hold
idle subscriptions without holding idle agent-admission slots. Every connect and
turn still uses Banyan's admission controller and CLI ownership fences.

The Python connector contains Slack transport and credentials. It calls only the
local authenticated native API. Disabling or detaching fences actions again at
the coordinator send boundary, including actions waiting for admission or locks.
Queues, attachments, operation receipts and connector delivery receipts persist
in private local journals. No token or conversation is written to connector logs.

## Setup on the Mac

1. Create a Slack app from [the reusable manifest](../integrations/slack/manifest.json).
   Install it into the intended workspace and invite the bot to the intended
   public or private channel. All participants in that channel can see posted
   conversation context; choose the channel membership accordingly.
2. Under Basic Information, generate an **app-level token** with
   `connections:write`. Keep it local as `SLACK_APP_TOKEN`. Keep the installation's
   **bot token** local as `SLACK_BOT_TOKEN`. Pass them through your local secret
   manager or environment; do not put them into the policy, source tree, launch
   arguments or logs. The manifest's bot scopes are `app_mentions:read`,
   `channels:history`, `groups:history`, and `chat:write`; its subscriptions are
   `app_mention`, `message.channels`, and `message.groups`. DMs are not subscribed.
3. Create a local policy file, for example `~/.config/banyan/slack-policy.json`:

   ```json
   {
     "enabled": true,
     "allowed": [
       { "workspace": "T_EXAMPLE", "channel": "C_EXAMPLE", "user": "U_EXAMPLE" }
     ]
   }
   ```

   Replace placeholders with exact Slack IDs. Each entry grants one tuple;
   separate workspace/channel/user lists do not create cross grants. An empty
   list or a disabled policy denies **all** remote reads and actions. Remote
   control defaults off. Additional users need explicit tuple entries.
4. With the intended Banyan channel running, apply the policy locally:

   ```sh
   banyanctl codex-remote configure --path ~/.config/banyan/slack-policy.json
   python3 -m venv ~/.local/share/banyan-slack/venv
   ~/.local/share/banyan-slack/venv/bin/pip install -r scripts/banyan_slack/requirements.txt
   ~/.local/share/banyan-slack/venv/bin/python scripts/slack-connector.py start \
     --config ~/.config/banyan/slack-policy.json
   ```

   Run from the Banyan checkout, with Python 3.10 or newer and the two local Slack
   environment variables available. SDK 3.45.0 is pinned. Startup checks bot
   workspace identity and the authoritative local policy before opening Socket
   Mode. Startup remains offline until a fresh Slack `hello` and successful
   authoritative synchronization; an SDK connection attempt alone does not
   claim connectivity. The foreground process prints content-free status notices.

The local token stays in `~/Library/Application Support/Banyan/control-token`;
it is sent only to loopback. The connector does not copy it into Slack or its
journal. `--control-url`, `--token-file` and `--state` support isolated fixtures
and explicit alternate app channels. The URL must be HTTP on `127.0.0.1`, with
redirects and proxy use disabled. Never reuse fixture tokens against the live app.

## Phone and desktop use

- In the allowed channel, send `@Banyan list` to see native session IDs, titles,
  projects, state and attention flags. Choose an already existing native row.
- Send `@Banyan attach SESSION_ID`. That user message becomes the explicit thread
  root. One session maps to one Slack thread, and one Slack thread maps to one
  session. Retrying or reconnecting restores that mapping and exact Codex ID.
- Reply in that thread. Input queues by default. It waits until the session is
  subscribed, idle and has no pending question/approval. When busy, the receipt
  offers **Steer current turn**. Steer consumes that queued entry atomically and
  targets the displayed turn; it cannot later run as another queued turn.
- Use **Approve Once**, **Deny**, or **Answer questions** on the status panel.
  Approval buttons are limited to server-offered choices. Questions open a modal
  with offered options or free text when supported. Secret questions and Slack
  form/schema limits require desktop input. Request/turn changes reject stale
  controls and refresh the panel. Desktop responses remove actionable controls
  even while awaiting the server's resolution acknowledgment.
- **Stop turn** interrupts only the displayed turn. It preserves the native row,
  thread history, settings and working directory.
- **Detach** removes the mapping and cancels its unsent queue. Desktop also shows
  attachment, connectivity, queue and reconciliation state with **Detach Slack**
  and **Disable Slack Control** controls. Another selected session does not stop
  observation of the attached session. Detach before switching to the CLI.

Recent context and progress update one status panel. Streaming tokens are not
posted. Completion, failure and new pending requests get concise separate
notifications. Text uses plain Block Kit fields and escaped fallback text, so
model output cannot create Slack mentions or controls.

## Stop, disable and recovery

Ctrl-C or SIGTERM stops the foreground connector, fences queued callbacks and
outbound sends, and marks it offline locally. A second process cannot share its
journal: an exclusive lock refuses startup. Accepted native work continues in
Banyan; accepted queues are owned by Banyan, including while the connector is
stopped. To stop subsequent remote work as well, use **Disable Slack Control**
on desktop, or apply the same policy file with `enabled: false` through
`banyanctl codex-remote configure`. Restarting the connector cannot enable the
local service or expand its allowlist.

A genuine transport outage removes controls from the published panel and shows
unavailable on desktop (the API lease expires if the process dies). Explicit
HTTP authorization denial suppresses outbound delivery, including offline
notices. Clean WebSocket closure, errors and refresh requests fence inbound
work until a fresh `hello` and authoritative state refresh. The SDK obtains a
new `apps.connections.open` URL on reconnect. API events use a bounded 256-event
cursor window and a process epoch; gaps/restarts refresh snapshots. Cursor
advancement happens after delivery decisions have been persisted.

A lost submission response is **uncertain**, not permission to send again.
The connector asks for the durable receipt on replay; the native queue pauses
behind uncertain outcomes. In the attached thread, `@Banyan reconcile` refreshes
Codex's authoritative history and displays receipt status. Inspect that history
on desktop, then explicitly acknowledge the outcome locally:

```sh
banyanctl codex-remote resolve --workspace T_EXAMPLE --operationID OPERATION_ID
```

This retains a replay tombstone and unblocks later queued messages. It **never**
resubmits the uncertain message. Definite pre-send denial/cancellation and
explicit RPC rejection are recorded as rejected, rather than blocking the queue.

Non-idempotent Slack posts also have write-ahead delivery receipts and automatic
HTTP retries disabled. Posts are paced to one per second per channel. Definite
HTTP 429 rejections persist as known-not-sent and retry after `Retry-After`, with
bounded async retries and fresh authorization plus exact attachment checks after
each wait. Detachment cancels pending attachment deliveries, including persisted
retries restored after reconnect. Status updates and question modals revalidate
the same binding before delivery. Remaining
known-not-sent deliveries resume on a later event/heartbeat; unknown outcomes
never enter that retry path. A lost post response is not posted again. The attachment
still refers to the user's known root message, so it cannot fork a new Slack
thread. To restore an uncertain status panel, stop the connector, inspect:

```sh
python3 scripts/slack-connector.py status
python3 scripts/slack-connector.py reconcile-post --key DELIVERY_KEY --ts EXISTING_SLACK_TIMESTAMP
```

Only record a timestamp after identifying the already delivered bot message in
its recorded channel/thread. Reconciliation records that existing message and
sends nothing. Restart the connector to refresh it. If no delivered message can
be established, keep the receipt uncertain and use desktop; do not erase it or
blindly retry a post. `status` displays only uncertain operation/delivery IDs
and correlation, never request bodies or tokens.

The native journal is `~/Library/Application Support/Banyan/remote/slack.json`
(32 MiB / 4096 receipts / 256 queued messages); the separate connector journal
is `~/Library/Application Support/Banyan/slack-connector/state.json` (16 MiB).
Both use atomic private writes and refuse new work at capacity. Preserve them
when restarting or troubleshooting: deleting deduplication evidence can permit
replayed actions. Storage corruption/write failures fail closed. Capacity
requires local maintenance while disabled; this MVP intentionally does not
silently evict replay evidence.

For missing events, check the bot's channel membership, workspace identity,
exact tuple IDs, installation scopes and event subscriptions. For unavailable
native rows, reconnect them on desktop and check the existing thread's storage
and writer status. Banyan never substitutes a replacement thread. For queued
input, check pending requests, active work, the shared admission queue and
uncertain receipts before retrying anything.

## Local API contract

All routes below are POST requests to the existing loopback control server with
`Content-Type: application/json` and the local `X-Banyan-Token` header. Responses
use the existing `{ "ok": true, "data": ... }` envelope; missing local tokens
return 401, remote policy refusals return 403, and stale/unavailable operations
return 409. Slack credentials never enter these requests.

`/codex-remote` takes an `action` and a `principal` tuple. `list` exposes native
metadata and existing identities; `sync` refreshes attachments and establishes
an online lease; `events` long polls with `epoch` and `cursor`, returning bounded
events plus authoritative snapshots. `offline` relinquishes the online lease.
`attach` requires `sessionID`, `threadID` and the existing Slack root timestamp
`slackThread`. All attached operations (`snapshot`, `reconcile`, `receipt`,
`detach`, `queue`, `steer`, `stop`, `respond`) require that exact session/thread,
`attachmentID` and `slackThread`. The principal must match its workspace/channel.

Mutations use a durable `operationID`; reusing it with different content fails.
`queue` adds `text`; explicit `steer` adds `text` and expected `turnID`, and may
consume its queued entry via `queuedOperationID`. `stop` requires expected
`turnID`. `respond` requires the exact JSON `requestID`, `turnID` and either a
server-offered `decision` or `answers` keyed by question ID. `receipt` retrieves
one operation's persisted outcome without submitting it. `reconcile` reads the
original Codex thread and refreshes both presentations without submitting input.

`/codex-remote-configure` accepts the local `enabled`/`allowed` policy, and
`/codex-remote-resolve` accepts `workspace`/`operationID` for explicit local
acknowledgment of uncertainty. These administration routes use the local token;
the Slack connector does not expose them as Slack commands.

## Verification and remaining gate

```sh
swift test --no-parallel --filter 'CodexRemoteControlTests|codexRemoteAuthenticatedHTTP'
python3 scripts/tests/test_slack_connector.py
python3 scripts/tests/test_slack_socket_adapter.py
# Also run adapter/runtime checks against the pinned SDK in the setup venv:
~/.local/share/banyan-slack/venv/bin/python scripts/tests/test_slack_socket_adapter.py
python3 scripts/verify-codex-integration.py --slack --codex codex
```

The installed fixture uses an empty Codex home and a disposable loopback
Responses provider. A fake Slack transport delivers messages, buttons and a
modal through the real authenticated HTTP server into `SessionStore` and the
installed App Server. It verifies original thread identity, exact start prompt
sequence, desktop conversation delivery with another row selected, approval,
question, explicit steer, queued follow-up, stop, replay, restart and disable.
The fixture writes disposable evidence to its printed private artifact directory
and reaps only its own children. No real Slack installation, credentials, live
Banyan settings, app restart or tmux environment is used.

- [ ] **Physical phone round trip**: continue an opted-in native session, answer
  a pending request and inspect desktop. Record Banyan/Codex/Slack/iOS versions
  and pass/fail without credentials or private conversation content. This remains
  unverified until a real Slack installation and physical-phone evidence exist.

Primary protocol references: [Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/),
[Python SDK Socket Mode](https://docs.slack.dev/tools/python-slack-sdk/socket-mode/),
[Web API client and retry handlers](https://docs.slack.dev/tools/python-slack-sdk/web/),
[chat.postMessage](https://docs.slack.dev/reference/methods/chat.postMessage/),
[Web API rate limits](https://docs.slack.dev/apis/web-api/rate-limits/),
[block actions](https://docs.slack.dev/reference/interaction-payloads/block_actions-payload/),
[Codex App Server](https://learn.chatgpt.com/docs/app-server).
