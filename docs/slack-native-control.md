# Supervising Banyan sessions from Slack

Banyan owns the App Server, session ID, thread ID, settings and pending requests.
Slack is an additional interface to existing sessions. The connector
runs on the Mac and uses outbound Socket Mode; no public endpoint is needed.
The Mac, Banyan and connector must remain running and awake. This interface
supervises existing sessions; it does not create sessions or support DMs.

## Design and ownership

The connector uses Banyan's authenticated loopback API. Banyan owns runtime
identity, history and input; Slack transport does not launch an agent.
`CodexRemoteControl` wraps Banyan's existing native coordinator.
Its observer registry preserves desktop callbacks. Attachment generations hold
idle subscriptions without holding idle agent-admission slots. Every connect and
turn still uses Banyan's admission controller and CLI ownership fences.

The Python connector contains Slack transport. It calls only the local
authenticated API. Disabling or detaching fences actions again at
the coordinator send boundary, including actions waiting for admission or locks.
Queues, attachments, operation receipts and connector delivery receipts persist
in private local journals. No token or conversation is written to connector logs.

## Setup on the Mac

1. Create a Slack app from [the reusable manifest](../integrations/slack/manifest.json),
   install it in the intended workspace, and invite the bot to one private
   control channel. Everyone in that channel can read posted conversation
   content. The connector verifies channel privacy and membership at startup.
   Generate an app-level token with `connections:write` under Basic Information.
   The manifest requests `app_mentions:read`, `channels:history`,
   `groups:history`, `groups:read`, and `chat:write`; it subscribes to mentions,
   channel messages, private-channel messages and App Home openings.
2. In a checkout, prepare Python 3.10 or newer with the pinned Slack SDK:

   ```sh
   python3 -m venv ~/.local/share/banyan-slack/venv
   ~/.local/share/banyan-slack/venv/bin/pip install -r scripts/banyan_slack/requirements.txt
   ```

3. In the explicitly selected Banyan installation, open Preferences and find
   **Slack integration**. Save the bot token and app-level Socket Mode token in
   Keychain, then add the exact workspace, private channel and allowed user IDs.
   Each entry grants one tuple; an empty allowlist denies all remote access. Set
   the Python interpreter path if it differs from the default and select
   **Enable and connect**. The credentials are kept in the macOS login Keychain,
   namespaced for that app installation; they are not written to the policy file,
   connector arguments or logs.
4. Preferences reports starting, connecting, connected, offline/reconnecting,
   stopped or failed. Connected requires a Slack `hello` and a successful local
   synchronization. **Reconnect** replaces the connector; **Disable** fences
   remote access and stops it. Disable before changing the allowlist or tokens.

The local token stays in `~/Library/Application Support/Banyan/control-token`;
it is sent only to loopback. The connector does not copy it into Slack or its
journal. `--control-url`, `--token-file` and `--state` support isolated fixtures
and explicit alternate app channels. The URL must be HTTP on `127.0.0.1`, with
redirects and proxy use disabled. Never reuse fixture tokens against the live app.

## Phone and desktop use

Open Banyan's App Home to search sessions, filter by Needs you, Working,
Recent or All, and page through projects. `@Banyan list` and
`@Banyan list SEARCH` also list matches in the control channel. Open a row to
create or reuse its session-bound thread. **Earlier messages**, **Latest**, and
where applicable **Terminal output** read context on demand; Away is not needed.
Browsing does not send input or resume a conversation. Transcript pages identify
their source and any truncation or staleness. When an exact terminal conversation
cannot be verified, retained pane output is read-only; it is not matched by
working-directory similarity. The bounded transcript window is at most 4 MiB,
with individual messages limited to 8,000 characters. For larger transcripts,
Banyan verifies a bounded prior checkpoint before retaining the conversation
binding; an unrecoverable gap creates a new generation. A read-only pane binding is retired after its
captured output or transcript window changes, an observed conversation reset,
or an app restart. Large or replaced files can invalidate a cursor;
reopen Latest. Puck history comes from bounded daemon events and can omit user
prompts or older events.

Follow sessions or projects in App Home and turn on **Away** for catch-up and
subsequent notifications. Turning Away off stops proactive delivery while
on-demand browsing remains available. Terminal decisions are actionable only
when Banyan identifies the exact current Codex prompt and conversation; a reply
is accepted only at a verified empty composer and must be one printable line.
Puck replies use the existing Puck session and admission controller. Puck
approvals and questions, including multiple selections and custom answers, can
be answered from their bound thread when they fit Slack's form limits. Oversized
or ambiguous questions require desktop action.
When input or a Slack post has an uncertain outcome, inspect the session and
receipt before acknowledging it locally; the connector does not retry it blindly.

The existing native Codex attachment controls remain available:

- Use `@Banyan list` in the allowed channel to find an existing native row.
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

For an uncertain terminal or Puck thread reply, after inspecting its outcome use
the same command with `--kind terminalFollowup`. This acknowledges the receipt;
it never resubmits input.

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
python3 scripts/tests/test_slack_session_browser.py
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

- [ ] **Physical phone round trip**: browse an existing terminal session, read
  context predating Away, answer a pending request and inspect the same session
  on desktop. Record Banyan/Codex/Slack/phone OS versions
  and pass/fail without credentials or private conversation content. This remains
  unverified until a real Slack installation and physical-phone evidence exist.

Primary protocol references: [Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/),
[Python SDK Socket Mode](https://docs.slack.dev/tools/python-slack-sdk/socket-mode/),
[Web API client and retry handlers](https://docs.slack.dev/tools/python-slack-sdk/web/),
[chat.postMessage](https://docs.slack.dev/reference/methods/chat.postMessage/),
[Web API rate limits](https://docs.slack.dev/apis/web-api/rate-limits/),
[block actions](https://docs.slack.dev/reference/interaction-payloads/block_actions-payload/),
[Codex App Server](https://learn.chatgpt.com/docs/app-server).
