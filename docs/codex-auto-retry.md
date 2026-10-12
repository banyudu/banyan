# Codex automatic retry

Banyan can continue an interrupted Codex task after a recognized transient
inference failure. The preference **Automatically retry transient Codex
failures**, under **Preferences → Codex**, defaults to enabled and persists
across launches. Recovery works independently of the command that launched the
session; no launcher script or Codex plugin is required.

## Policy

There are at most four automatic continuation attempts per interrupted task.
Nominal delays are 15, 30, 60, and 120 seconds, each with ±10% jitter. Successful
completion or a new user turn resets the budget. A banner shows the next retry,
attempt count, error, and **Cancel Retry**. After the budget is exhausted it
shows that retries have stopped.

Recovery sends a short continuation asking Codex to check the current state and
completed tool results before repeating actions. It retains the conversation,
model, and permissions. It does not restart a process or replay the original
task. This continuation is not a transactional replay: Codex still determines
the next tools to run from the conversation and working directory.

Supported errors include capacity/overload, temporary request rate limits,
HTTP 408/429/5xx connection errors, and interrupted connections/response streams.
Quota or budget exhaustion, authentication, context limits, approvals, policy
blocks, and unrecognized errors require user attention. Failed retry submissions
stop recovery because their delivery may be uncertain.

Typing (including paste and IME composition), interrupting, closing, parking,
freezing, disabling the preference, or starting another turn cancels pending
recovery. Cancelling suppresses redraws of the same failed task until a new user
turn. Pending attempts and budgets are in memory and are not restored after an
app restart.

## Native sessions

The adapter waits for `turn/completed` with `status: failed`, classifies the
structured error, and respects the preceding `error.willRetry` signal. It does
not compete with Codex's own retries. Authorization checks run again after
admission and subscription waits, before `turn/start`: the original thread,
settings, failed turn, empty draft, and lack of pending requests must still match.
Background failures keep their event subscription while recovery is pending.

## Terminal sessions

The existing supervisor supplies candidates, including background sessions with
no loaded terminal view. No extra polling loop is added. A candidate requires:

- Exactly one logical Codex agent with readable kernel process identities.
- An idle pane outside tmux copy mode.
- A recognized `■` error directly above an empty Codex composer and its shortcuts
  footer. Wrapped capacity messages are supported; other ambiguous multiline
  errors and unknown composer placeholders are left for manual recovery.

After the delay, Banyan freshly inspects the pane, composer, process identities,
session ownership, and conversation identity. A CLI that yielded its agent slot
waits for admission before those checks; queued recovery is also cancellable.
It sends continuation text and Enter together in a single asynchronous tmux
command. A cancellation token and
kernel identity checks also fence work queued behind other subprocess I/O.

Terminal recovery is conservative and depends on the CLI's rendered layout. An
external terminal client can race the final capture and submission; terminal
input has no atomic compare-and-send protocol. Native sessions have stronger
turn identity checks. Cancel stops pending work; input already delivered cannot
be retracted. Puck-backed Codex sessions are outside this policy because their
daemon owns the runtime.

## Verification

```sh
swift test --no-parallel --filter 'CodexRetry|CodexAutoRetry|codexRetryPrompt|SessionDetailOverlayTests'
```

Tests use a controlled clock, synthetic App Server events, a synthetic tmux
backend with kernel identity checks, and an offscreen rendered banner. They do
not call a paid inference provider or send input to existing sessions.
