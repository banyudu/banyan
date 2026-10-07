# Native Codex integrated verification

The integrated backend was checked on macOS 27.2 arm64 with `codex-cli 0.160.0`,
starting from merged `main` at `54ef966` and applying the focused fallback and
UI corrections described below. This is acceptance evidence for the native
backend epic, not a claim that each prerequisite PR alone proves integration.

## Reproduce without credentials

```sh
python3 scripts/verify-codex-integration.py --codex codex
swift test --no-parallel
BANYAN_TEST_INSTALLED_CODEX=1 swift test --filter installedCodexSchemaStartupAndExactThreadResume
```

The runner prints its private disposable artifact directory before starting.
It uses an empty `HOME`/`CODEX_HOME`, a deterministic HTTP/SSE Responses provider
bound to loopback, and the installed Codex executable. Inference never reaches
a paid provider. The two native threads use separate synthetic model/provider
settings; tools, RPC, the agent loop, SQLite persistence, and native view are
real. Plugin catalog fetching is disabled in this fixture to keep startup and
RSS samples independent of background catalog downloads. User credentials,
running Banyan channels, and live tmux environments are not used.

The opt-in Swift test constructs `SessionStore` and `CodexSession`, renders
`CodexSessionDetail` in an offscreen `NSHostingView`, and verifies visible text
with Vision OCR. It invokes the same session actions wired to the view's
controls. The Python runner opens the generated CLI fallback command in a
private PTY and submits an actual prompt, checking completion in the original
thread rollout. This is stronger than fake JSON-RPC responses or `--help`.

Artifacts include `manifest.json` (version, command, cleanup result),
`rpc.json`, `events.json`, `settings-evidence.json`, approval/input/restored
PNGs and OCR text, `cli-pty.log`, `cli-result.json`, three idle memory result
files with all process-tree samples, and `native-unload.json`. They contain
disposable paths/IDs and remain private; do not commit the raw directory.
The runner stops only its own processes. Review the manifest's open-file PID
check before removing the artifact directory.

## Acceptance evidence

| Criterion | Integrated evidence |
| --- | --- |
| Multiple independent sessions in one server | Two native rows have distinct IDs/cwds, models, provider selections, reasoning effort, and permission settings. One owned App Server launch serves both. Additional fresh 1/2/4-thread runs check loaded counts and idle subscriptions. |
| Banyan-owned endpoint | Production starts `app-server --listen stdio://` with private pipes. A separate fixture App Server initializes concurrently with an independent empty loaded list while the original server retains four threads. No Desktop socket is opened or replaced. |
| Create/resume and streamed activity | Successful user/agent turns and `item/agentMessage/delta` reach the native conversation. A real `exec_command` tool produces a completed command item and a disposable proof file only after approval. |
| Approvals and input | Pending requests stay on their original row while selection changes. Approve Once runs the command; Cancel Turn prevents a second proof-file write. A real `request_user_input` call receives the selected answer. Only server-offered approval decisions appear. |
| Steering and interruption | A held inference stream receives `turn/steer` with its expected turn ID. A different held turn receives `turn/interrupt` and ends `interrupted`. Both use the native session actions. |
| Restart identity/settings | After reaping the owned server, a fresh client and `SessionStore` load the private SQLite DB, resume both exact thread IDs/cwds/settings, hydrate history, and complete more turns. Actual rollout turn contexts confirm policy, sandbox, model, and effort. |
| Unsubscribe versus unload | Background idle rows unsubscribe and discard their client transcript while the server still lists them as loaded. All four later receive server unload events and become `notLoaded`. Native UI/OCR explains the inactivity grace period. |
| Measured idle RSS | Same-count native and interactive CLI process trees are sampled at 1/2/4 fresh idle sessions. See the measurement details below and the earlier spike. |
| CLI fallback | Unsupported explicit `untrusted` CLI configuration is rejected before conversion; the original native row and settings remain usable. The supported `never/read-only` row resumes the exact thread in an interactive CLI and completes a turn. Fallback includes `--no-daemon`. |
| Compatibility isolation | The adapter continues to gate the tested protocol versions, with existing unsupported-version, missing-capability, and disconnect coverage. The installed smoke test generates the binary's schema and exercises startup/resume. |

The functional settings are `fixture-model` / `loopback` / low effort /
`untrusted` / `workspace-write` and `fixture-second` / `loopback_second` / high
effort / `never` / `read-only`. Both provider definitions point exclusively to
the disposable loopback server. Neither permission policy is relaxed.

## Integration corrections

App Server accepting a policy does not prove that the interactive CLI accepts
the same value in its configuration. Codex 0.160.0 accepts RPC `untrusted` but
rejects explicit CLI `approval_policy="untrusted"` during config loading. The
existing parser-only smoke test could pass while the actual TUI failed.
The [upstream config loader](https://github.com/openai/codex/blob/main/codex-rs/core/src/config/mod.rs)
and [official migration guidance](https://learn.chatgpt.com/docs/agent-approvals-security)
describe this retirement. Automatically substituting `on-request` would change
the approval rule, so Banyan does not do that.

Banyan now probes CLI bootstrap with the exact persisted overrides before
reaping the server or replacing the row. Failure gives an actionable error and
preserves native ownership. Successful validation is followed by another busy
check because turn/approval notifications can arrive during the probe.
Regression tests cover rejection and work arriving at this await boundary.

The generated fallback also passes `--no-daemon`, retaining a standalone owned
CLI path rather than joining a Desktop/CLI-managed server. The terminal freeze
foundation merged in `54ef966` remains separate: native Codex rows reject
terminal-freeze requests and rely on thread subscription/unload instead.

## Idle memory and grace period

The original [0.146.0 spike](codex-app-server-spike.md) measured four idle
threads at 394,912 KiB versus 401,808 KiB for four TUIs: approximate parity,
not a demonstrated large memory reduction. Keep that result intact.

Current samples use the npm-distributed 0.160.0 executable, identical private
provider configuration, `never/read-only`, no inference/history, and fully
initialized interactive composers. Counts are equal on both sides. Each RSS
total sums the launched agent's entire process tree, including the npm Node
launcher and any descendants. Banyan's UI process, the Python provider, and tmux
are excluded from both agent-runtime totals. Three samples are taken 250 ms
apart after the CLI composers settle for two seconds; the middle sample is
reported, with all samples retained. RSS can count shared pages repeatedly.
These are controlled idle-runtime samples, not whole-app or authenticated
production-workload savings.

| Idle sessions | Shared App Server tree RSS (KiB) | Per-session CLI trees RSS (KiB) |
| ---: | ---: | ---: |
| 1 | 122,400 | 149,392 |
| 2 | 124,544 | 301,392 |
| 4 | 128,960 | 601,648 |

This current fixture shows lower aggregate agent RSS as idle session count
increases. It does not supersede the earlier binary's parity result or establish
the same savings for authenticated production sessions.

The accepted 0.160.0 binary emitted `thread/closed` after 60.334 seconds in the
independent unsubscribe probe, and the integrated coordinator also observed
all four idle threads unload after approximately 60 seconds. The original
0.146.0 probe observed 30 minutes and 4 seconds. Unload grace is version-dependent;
Banyan renders the server's events and explains the delay without hardcoding
a universal 30-minute timer. Increase the runner's `--unload-timeout` when
checking a binary with a longer grace period.

## Remaining external checks

The local harness proves native integration without an account or inference
service. It does not prove ChatGPT entitlement, token refresh, Desktop/mobile
handoff, external-writer conflict resolution, or production RSS with an
authenticated plugin/catalog workload. Those require the appropriate external
client/account and remain separate live checks. No result here asserts that
unsubscribe immediately releases a writer to another client.

The supervisor owns merge and signed-app runtime verification. This PR does
not restart the live app, freeze live agents, close the epic, or merge itself.
