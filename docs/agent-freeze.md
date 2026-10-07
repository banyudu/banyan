# Agent process freezing (macOS)

Banyan can send `SIGSTOP` to an inactive terminal agent's verified process
groups, including MCP descendants, and later send `SIGCONT` to the same groups.
This is separate from **Suspend/Resume**, which parks the frontend while leaving
the agent running. Native Codex app-server and puck sessions share a service
process and are not eligible for process freezing.

Automatic freezing is **off by default**. Enable **Preferences → Sessions →
Automatically freeze inactive agents** to opt in. The baseline idle threshold
defaults to 10 minutes and can be set from 1 to 120 minutes. It is multiplied by
0.75 when Banyan is in the background, by 0.75 on battery, and by 0.5 with eight
or more live terminal sessions; the effective minimum is one minute. Disabling
the preference resumes frozen agents. Preferences persist across app launches.

To freeze manually, first select another session and let the target become idle:

```sh
banyanctl session freeze --id SESSION_ID
banyanctl session unfreeze --id SESSION_ID
```

The top-level `freeze` and `unfreeze` commands are aliases. They use authenticated
`POST /freeze` and `/unfreeze` control routes with the existing `id` payload.
Session summaries and pane output include a separate `isFrozen` boolean.
`suspend`/`resume` retain their existing parking behavior.

The sidebar shows a native snowflake badge, “Frozen — interact to resume,” and
offers **Freeze Agent / Unfreeze Agent** in the context menu. Selecting the row
resumes it before terminal attachment. CLI input and prompt answers resume it
before writing any keys. Closing/removing/restarting a frozen session resumes
its verified groups before teardown; normal application termination resumes
all frozen agents.

User Ctrl-Z/SIGTSTP is separate from a Banyan freeze and has no freeze ticket.
Recover it explicitly with `banyanctl session unfreeze --id SESSION_ID` or the
row's **Resume Stopped Agent** action. This path freshly verifies the pane's
identity and hosted/agent groups before CONT. The launch host never automatically
continues STOP/TSTP children during ordinary operation, so it cannot undo an
owned freeze. HUP/TERM teardown continues a stopped command before forwarding
the terminating signal, allowing it to exit.

## Eligibility and safety

Both manual and automatic paths require all of these:

- A live, unparked terminal agent in `.idle` or `.needInput`, freshly classified
  by the supervisor. Executing, subagent, shell-work, asking/review, closed,
  history, and shared-service sessions are excluded.
- Neither of Banyan's selection models points at the session. This protection
  remains in force even when the application is hidden.
- No attached tmux client and no tmux copy mode. External clients and retained
  hidden frontend clients conservatively block freezing; detaching them allows
  a later attempt.
- No pane output or interaction for the effective threshold (two seconds for a
  manual request), with a known tmux activity timestamp.
- At most 1% of one CPU core across the **entire** process tree over a one-second
  libproc sample, with no PID reuse, missing sample, tree/group change, or input
  in flight. Quiet output alone does not establish eligibility.

The launcher retains the pane PID and microsecond kernel start identity. At
freeze preparation the agent PIDs, start identities and process groups are
recorded. A pane must be a dedicated kernel session; every group must have a
live, identity-verified leader, belong to that pane, and contain no process
outside the pane tree. Banyan's process and process group are protected. Detached
descendants, unreadable members, shared groups, and stale identities cause a
refusal. The final focus/input guard and STOP run without an actor suspension;
group identity is checked immediately before signaling. A tree change during
STOP causes rollback with CONT. Signaling snapshots use kernel enumeration
only and fail closed on a read failure; they never fall back to a `ps` subprocess
on the UI actor. macOS has no atomic “signal group if start time
matches” syscall, so identity checking narrows the kernel exit/reuse race rather
than claiming to eliminate it.

On macOS, packaged Banyan includes `banyanctl` beside the app executable as a
small native process host. It launches nonempty commands in their own foreground
process group and waits without restarting stopped jobs. The pane root stays
running: tmux itself immediately continues a stopped pane-root process, so
stopping that group cannot implement a reliable freeze. Interactive shell panes
can also run eligible agents in separate job-control groups. Existing agents
which share their pane-root group safely refuse freezing and need relaunching
with the current host. Standalone development binaries resolve the sibling
`banyanctl`; `BANYAN_PROCESS_HOST` can explicitly specify the helper executable.
If no helper is available, legacy launches still work and shared-root agents
remain ineligible. Linux terminal launch behavior is unchanged.

The host blocks HUP/TERM before spawn, installs forwarding, publishes the child
group and then restores its signal mask. The command receives a clean signal
mask and default terminal signal dispositions. Normal exits preserve the exit
code; signal exits use shell convention `128 + signal`. Normal command exit does
not terminate background children or sweep the kernel session. Deliberately
backgrounded/nohup servers preserve ordinary terminal semantics. Explicit
close/restart of a frozen session terminates only the verified groups in its
owned freeze ticket, including frozen MCP groups. Descendants that detach into a different
kernel session remain outside this ownership boundary and block freezing while
still in the sampled agent tree.

Before STOP, the complete identity ticket is journaled as a private tmux session
option. Relaunch recovers the ticket, and resumes it immediately if automatic
mode is off or the session is selected. PID identities are checked again on
CONT; if a group leader died, only identity-verified surviving members are
continued individually. A reused PID or PGID is never accepted as the original.
The journal is removed after a successful resume. Abrupt app death can leave
agents stopped until app relaunch/unfreeze; tmux retains the journal.

## Scheduling and tradeoffs

Freezing uses the existing adaptive supervisor wakeups, not a new repeating
timer. With automatic mode enabled, the maximum probe interval is a quarter of
the effective threshold, clamped to 15–120 seconds. This caps long idle-session
backoff so opt-in automatic mode actually runs. Expensive CPU samples occur
only for unfocused idle candidates. Output, focus and input invalidate pending
preparations. Frozen panes skip normal classification; existing supervisor
wakeups reconcile external CONT, process death and external client attachment
within 15 seconds. Native selection/input resume synchronously.

STOP preserves the agent's address space and does **not** release RAM
immediately. It prevents page touching and idle growth, allowing macOS to
compress/swap pages under pressure. Resuming evicted pages can stall while they
fault back in. Connections may expire while stopped; reconnect behavior belongs
to each agent/provider. This feature relies on the supervisor's visible
mid-turn markers: a provider that displays an idle prompt while silently doing
work can defeat that proxy. Automatic mode remains an explicit opt-in.

`AgentInactivityPolicy` and the kernel identity/group planning in
`AgentProcessFreezer` live in BanyanCore for reuse by future deep suspension.
Deep suspension, deterministic memory reclamation, and shared-service freezing
are outside this feature.

## Verification

```sh
swift test --filter 'AgentFreezeTests|agentFreeze|agentInactivity'
swift test --filter agentProcessHost
python3 scripts/tests/test_package_app.py
swift test
swift build --product Banyan
swift build --product banyanctl
```

The regression suite uses synthetic Python agents, allocated memory, MCP
children in a separate process group, a local TCP peer, private databases, and
UUID tmux sockets. It never stops a real user agent or touches the live tmux
server. The TCP peer expires a socket during STOP and the synthetic agent
reconnects after input resumes it. STOP/CONT preserves its PID/start identity
and allocated address space; the tests make no deterministic RSS-reclamation
claim.

Private installed-CLI startup checks on 2026-10-07 used fresh homes, workspaces
and UUID sockets, without sending model prompts. Claude Code 2.1.286's
startup/login UI survived STOP/CONT with the same kernel identity. Codex CLI
0.160.0 and OpenCode 1.18.34 reached idle prompts but spawned descendants in
detached kernel sessions; this shape fails the planner's ownership rule before
STOP. Those versions' freeze/resume compatibility remains a concrete gap, not
a successful provider verification. Shared/detached runtime ownership needs a
provider-specific decision before relaxing that safety boundary.

Live provider checks remain separate: in disposable sessions, verify Claude,
Codex CLI and OpenCode at an idle prompt, after socket expiry, and during a
long-running turn. Confirm idle freeze/resume preserves conversation state and
the next prompt works, while active turns and focused sessions refuse freezing.
Do not use existing user sessions for these checks.
