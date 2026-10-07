# Deep suspend

Deep suspend releases an idle terminal agent's address space by sending SIGTERM
to **only the verified provider PID**. It retains the tmux session, exact pane,
scrollback, login shell, working directory and exported shell environment.
MCPs and background servers are preserved; children of an exiting agent may
become orphans. They are never group-signaled as part of deep suspension.
Their memory is not counted as reclaimed. Tier-one freezing remains useful for
short absences; see [agent freezing](agent-freeze.md).

Freezing leaves the runtime's address space allocated. Immediate reclamation
therefore needs process exit, together with a parent that survives that exit and
authoritative recovery identity. Deep suspend combines those three pieces;
it does not depend on swap eviction or escalate an unresponsive agent to KILL.

```sh
banyanctl session suspend SESSION_ID
banyanctl session resume SESSION_ID
# --id SESSION_ID also works
```

These use authenticated `POST /agent-suspend` and `/agent-resume` routes.
Top-level `banyanctl suspend` / `resume` retain frontend parking behavior.
Sidebar **Deep Suspend Agent / Resume Agent** uses the deep lifecycle. The UI
and `/list` expose suspended, terminating and resuming states separately.
Focus or interaction starts recovery. Input during startup is refused rather
than sent to a shell; API clients should retry after `isDeepResuming` clears.

## Policy and safety

Preferences has separate automatic/off switches and idle thresholds for Claude,
Codex and OpenCode. All are off by default; the default deep threshold is 45
minutes. A dispatch memory-pressure source escalates warning/critical pressure
to one quiet minute and selects the least recently interacted eligible session.
Continued pressure reuses adaptive supervisor wakeups to reclaim further LRU
agents. Normal pressure restores the configured time threshold.

Selected sessions, attached clients, copy mode, in-flight input, active turns,
output activity, CPU activity, changed process identities, incomplete process
trees and detached/shared services all refuse termination. The same kernel
start-time/session/group guards used by tier one remain in force. A quiet CPU
and output sample supplements the provider's idle status; output alone cannot
prove a waiting API request is safe to terminate.
Codex also requires a completed turn in its exact held rollout. Bounded header
and tail checks reuse the Remote handoff protocol; `task_started`, `user_message`,
`turn_aborted`, malformed or incomplete writes reset/refuse completion. This is
checked again immediately before TERM, independently of frontend status.

Recovery is recorded in a tmux journal **before** SIGTERM. Resolution uses
current provider argv, disk storage and process-bound current-session evidence.
Codex must hold the matching JSONL. Claude and OpenCode use the supported live
APIs described below, including when no JSONL is held open. A stored launch ID or disk existence alone
does not establish the current conversation after an in-app session switch.
Multiple IDs, conflicting open
transcripts, missing disk sessions, unsupported launch options and heuristic
"newest session in cwd" matches are refused. No initial prompt is replayed.
Resume retains the provider executable and supported launch options, including
Codex sandbox, approval, profile, config and model settings. Unknown options
refuse suspension rather than risk changing permissions.

A TERM timeout leaves a **terminating** recovery ticket; it does not claim RAM
was released. A process-exit notification observes a later graceful exit, then
marks suspended. An unreadable task sample alone is not exit evidence: kernel
identity/zombie state or ESRCH must prove the old address space is gone. Unknown
inspection retains the terminating ticket and blocks a second launch.
There is no SIGKILL escalation. Startup checks the new
provider's actual argv, exact resume ID and provider readiness. The intended
session must also be confirmed by the held transcript or live provider adapter;
argv plus a stale pane prompt cannot establish readiness. If that evidence is unavailable, recovery remains
uncertain. Retry reconciles an existing slow startup before sending another
command. Failure or conflicting identity retains recovery for inspection/retry.
Startup modals (including provider update prompts) also retain recovery. This
release does not auto-answer them or enable ordinary input before exact
readiness. Inspect the pane and resolve the modal through an operator-controlled
terminal only after verifying its pane/root and intended provider/session; then
retry Resume to reconcile that existing process. An in-app startup-input escape
path still needs an explicit identity-bound interaction design. Private fixture
configuration disables update checks; production settings are preserved.
A surviving shell must own the foreground terminal before a
resume command is inserted. Verified pre-existing background survivors may
remain in its process tree.

Restored panes distinguish an absent journal from an unreadable, empty or
malformed journal. Unknown recovery state blocks input and remains retryable;
it never becomes a cached absence. Valid recovery is bound to the pane's kernel
identity. A confirmed normal absence is cached, avoiding tmux reads on each key.

## Owned launches and legacy panes

The persistent host wraps a **literal** Claude/Codex/OpenCode invocation in a
surviving shell and an inner foreground process host. An `exec provider` launch
can exit without killing the outer shell. Foreground TTY/job control and the
one-shot host mode used by existing launches remain available. Resumes inherit
the surviving shell's exports without re-running login startup files.

Banyan's built-in Claude/Codex launches and `agent run --agent …` use explicit
owned modes: Claude pins `--session-id`, Codex uses `--no-daemon`, and OpenCode
sets `OPENCODE_DISABLE_AUTOUPDATE=true`. Configured/custom command programs are
preserved. To opt an existing custom profile into owned launches, use a literal
invocation, for example:

```sh
codex --no-daemon -s read-only -a untrusted -p YOUR_PROFILE
claude --session-id YOUR_UUID
env OPENCODE_DISABLE_AUTOUPDATE=true opencode --session YOUR_SESSION_ID
```

Codex shared-daemon/remote attachments, OpenCode external servers, forks,
one-shot subcommands and uncertain wrapper launches remain ineligible.

## Current-session adapters

New literal Claude/OpenCode launches receive a private, pane-lifetime plugin.
Each query carries a fresh nonce and the exact provider PID; replies must match
both, the provider's kernel start time, canonical cwd and an existing disk
session. An installed adapter that is disabled, unsupported or unavailable
refuses suspension and preserves recovery. It never falls back to a stale
launch ID. Normal launches continue when an adapter cannot be installed.
A bounded `--version` probe requires Claude 2.1.277+ (major 2) or OpenCode
1.18.34+ (major 1) before adding plugin options/config. Unknown versions retain
their original command and remain ineligible; future API failures also fail closed.

Claude's [mods API](https://code.claude.com/docs/en/plugins/mods/api) supplies
live `session.id()` / `session.cwd()` getters, turn events and background-agent
status. One owned native helper waits on filesystem requests and provider-exit
notifications. Repeated or overlapping `session.start` events reuse that loop
and refresh its API context. There is no periodic per-agent polling timer; a
540-second deadline renews the helper before the process API's ten-minute
timeout. Suspend/startup queries wait at most two seconds for a fresh answer.
Custom plugin directories remain alongside Banyan's plugin.

OpenCode's [1.18.34 TUI plugin contract](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/specs/tui-plugins.md)
supplies the current route and session record, server session status, pending
permissions/questions and dialog state. This binds the selected session in its
SQLite store to the actual TUI process. A filesystem watcher answers on demand;
switches during a query, busy background sessions and pending interaction refuse
suspension. Global/project TUI plugins and settings merge with Banyan's additional
config layer. An already-set `OPENCODE_TUI_CONFIG` is left untouched and disables
automatic bridge installation. Move equivalent settings to the standard global
or project `tui.json` before using deep suspend; do not change a running agent's
configuration. Pre-adapter panes still require exact held-transcript evidence.

Existing panes created with the old host, or commands such as
`cd ~/dev/my-project && codex …`, **do not gain a surviving shell retroactively**.
The refusal tells the user to relaunch with a literal provider command. Keep
the original session running, obtain its provider resume ID, and create a new
session using the existing working-directory option:

```sh
banyanctl session new --cwd ~/dev/my-project --command 'codex --no-daemon resume YOUR_UUID'
```

Verify that the intended conversation was restored before closing the old
session. Banyan never rewrites a shell program or signals a legacy agent to
perform this migration.

## Verification

```sh
swift build --product banyanctl
swift test --filter 'AgentDeepSuspendTests|deepSuspend|ownedLaunch'
swift test --filter 'AgentFreezeTests|agentFreeze|agentProcessHost'
swift test --filter providerIdentity
swift build --product Banyan
python3 scripts/verify-agent-deep-suspend.py --codex /path/to/codex
python3 scripts/verify-provider-identity.py claude --executable /path/to/claude
python3 scripts/verify-provider-identity.py opencode --executable /path/to/opencode
python3 scripts/verify-provider-identity.py claude --disabled
python3 scripts/verify-provider-identity.py opencode --disabled
python3 scripts/verify-provider-identity.py opencode --custom-tui-config
python3 scripts/verify-provider-identity.py claude --unsupported-adapter
python3 scripts/verify-provider-identity.py opencode --unsupported-adapter
```

Fixtures use private homes/transcripts, synthetic provider executables,
96 MB allocations, background children and UUID tmux sockets. They prove
agent-only termination, absent RSS after exit, same-pane/exact-ID recovery,
cwd/exports/foreground TTY continuity, focus races, unresolved IDs, ignored and
delayed TERM, busy shells, wrong-session startup, delayed-ready retry without a
second process, journal read/corruption failures and failed restart recovery.
Closed-JSONL fixtures exercise Claude/OpenCode recovery through their bound
adapters. Executable JavaScript contract tests cover overlapping session starts,
one helper, refreshed session state, pending interactions and disposal.

Private installed-provider startup evidence on 2026-10-07 established owned
STOP/CONT trees for Codex 0.160.0 with `--no-daemon` and OpenCode 1.18.34 with
`OPENCODE_DISABLE_AUTOUPDATE=true`. OpenCode's default detached bash/curl pair
was its release-update check. Claude startup/login also survived STOP/CONT.
These are ownership prerequisites. The opt-in installed Codex check reuses the
credential-free loopback Responses harness: it completes inference, proves PID
exit/prior RSS and surviving pane/shell/cwd/exports, resumes the exact disk ID,
and completes another turn. Its artifacts stay in a private temporary directory.
It also holds a real quiet Responses stream, deliberately marks the frontend
idle, and proves refusal with the same provider PID and no recovery journal.
Installed Claude 2.1.286 and OpenCode 1.18.34 adapters also passed credential-free
loopback checks for switched IDs, an in-flight request refusal and recovery,
custom plugin/settings preservation and disabled-adapter refusal with a usable
normal agent. Claude repeated switches retained one helper, which exited with
its provider. These checks use the real plugin APIs rather than generated-source
string assertions. Authenticated Claude/OpenCode recovery and MCP reconnect,
production pressure delivery and native UI timing remain supervisor/live
checks in disposable sessions. Do not use existing user agents for them.

`banyanctl perf report --since 7d` includes `agent.deep_suspend`,
`agent.deep_resume` and `agent.deep_suspend_refused`. Reclamation events record
the exited provider's prior RSS; they do not promise an equivalent drop in
machine-wide used RAM or count preserved children as freed memory.
