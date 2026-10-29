# Banyan

Banyan is a workspace for running and supervising many long-lived terminal
and coding-agent sessions. Shell and legacy agent sessions use `tmux`; puck
sessions live in one `puckd` process. Closing or restarting a frontend leaves
either backing session running.

This repository provides three products over one shared runtime:

- **Banyan** — native macOS SwiftUI app with embedded SwiftTerm terminals.
- **BanyanTUI** — terminal frontend for Linux and macOS.
- **`banyanctl`** — local CLI for creating, selecting, marking, closing,
  recovering, and inspecting sessions, and for suggesting work a human approves
  before it starts.

> Early preview: Banyan is under active development and is not yet a polished
> signed/notarized product. Expect interface and command changes.

The first screen is the working surface:

- left sidebar: sessions, status signals, tone, title, and compact session actions
- right side: the selected terminal session
- shell and legacy sessions use persistent `tmux`; puck sessions use durable daemon state
- programmatic control is available through `banyanctl`

### Session jump shortcuts

The macOS sidebar assigns shortcuts to the sessions currently visible, starting
at the top: `Cmd+0` through `Cmd+9`, then `Cmd+Shift+A` through `Cmd+Shift+Z`
(except J, K, L, N and S, which are reserved), then `Cmd+F1` through `Cmd+F12`.
Scrolling reuses these keys for the rows brought into view. Assignments stay
fixed while Command is held, and the Terminal menu and command palette show
the same shortcuts as the sidebar.

Visible-row rolling is enabled by default. To restore shortcuts based on the
full sidebar order (the first 43 sessions), add this top-level setting to
`~/.banyan/config.yml`:

```yaml
visible_row_shortcuts: false
```

Config edits apply without restarting Banyan. Remove the setting or set it to
`true` to enable rolling again. Use `Cmd+P` to search for an offscreen session.

### Session navigation

- `Cmd+J` / `Cmd+K` move to the next and previous session.
- `Cmd+Shift+J` / `Cmd+Shift+K` move to the next and previous project,
  selecting that project's top session.
- `Cmd+Home` / `Cmd+End` jump to the first and last session.
- `Cmd+PageUp` / `Cmd+PageDown` move by one screenful of visible session rows.

Adjacent and project navigation wrap around the sidebar. First/last and paging
stop at the ends instead. Plain `PageUp` / `PageDown` remain terminal scrollback
commands, so the session chords keep `Command` held.

### Linear keyboard navigation

When the Linear sidebar is active, use `Cmd+J` / `Cmd+K` to move through issues,
`Cmd+L` to open the selected issue, and `Cmd+Return` to start a session for it.
`Cmd+Shift+L` switches to the Linear sidebar and `Cmd+Shift+S` switches back to
Sessions. The existing `Cmd+J` / `Cmd+K` shortcuts continue to move through
terminals when the Sessions sidebar is active.

### Jumping to sessions that need you

`Cmd+Opt+J` / `Cmd+Opt+K` move forward and back through only the sessions that
are blocked on you — asking, needing input, or failed — wrapping around the
sidebar order. Idle shells and imported history are skipped, and a parent is
skipped while anything below it is still waiting, so the chord lands where
input is actually needed; a parent with nothing waiting beneath it stays a
stop. The chord stays
put when the session you are on is the only one waiting, so nothing happens
silently. Both directions are also in the Terminal menu and the command palette.

The toolbar is intentionally small:

- `+` forks the selected session's working directory into a new default shell.
- `slider.horizontal.3` opens Preferences for app theme and terminal font.
- Banyan checks GitHub Releases for updates, downloads new packages in the background, and offers to install and relaunch after confirmation.
- Sidebar options, including sort order and custom session creation, live behind the small sidebar menu.
- Restored sessions attach to existing `tmux` sessions when possible.
- Optional [agent freezing](docs/agent-freeze.md) stops inactive terminal agent
  process groups and resumes them on interaction. Automatic mode is off by default.
- [Deep suspension](docs/agent-deep-suspend.md) terminates verified idle agent
  processes to reclaim RAM and resumes their saved conversations in the same
  pane on focus. Per-provider policies support memory-pressure-aware LRU selection.

## Quick start

Clone the repository and enter it:

```sh
git clone https://github.com/banyudu/banyan.git
cd banyan
```

Then follow the macOS or terminal-only instructions below. Banyan is designed
for personal workspaces: the database, control token, and tmux sessions stay
on the machine where the frontend is running.

## Requirements

Banyan requires Swift 6.3 or a compatible Swift toolchain and `tmux` for shell
and legacy terminal sessions. Puck sessions require `puckd`. The macOS app
requires macOS 14 or newer. The TUI builds on Linux and macOS without SwiftUI
or AppKit.

```sh
brew install tmux
```

On Debian/Ubuntu Linux:

```sh
sudo apt install tmux
```

Banyan owns the native macOS UI. `tmux` owns shell and legacy agent processes;
`puckd` owns puck sessions. Detaching from Banyan closes only that client's
attachment.

Banyan uses a dedicated tmux socket namespace:

```sh
tmux -L banyan ls
tmux -L banyan attach -t banyan-Shell
```

This keeps Banyan sessions out of the default `tmux ls`, while still allowing manual attach/debug when needed.

## Build

```sh
swift build -c release
```

On Linux, the package also builds a terminal frontend that runs without
SwiftUI or AppKit:

```sh
swift build -c release --product BanyanTUI
.build/release/BanyanTUI
```

`BanyanTUI` uses the same SQLite session state, dedicated tmux backend, agent
status detection, and local history importer as the macOS app. In the TUI,
`j`/`k` or the arrow keys navigate, Page Up/Down move by a page, `e` renames
the selected session, Enter attaches or resumes, `n` creates a shell, `N` creates a custom titled/command session, `c` closes, `x` removes, `R` recovers a missing
backing session, `h` toggles history, and `T` resumes history with transcript
trimming. Puck sessions also appear in the active list; Enter attaches to the
selected daemon session. Press `p` for the daemon's create and attach menu.
The detail pane shows the selected legacy session's status, working
directory, command, tmux name, and latest terminal output. Press `q` to quit.

For a packaged macOS build:

```sh
./scripts/package-app.sh
./scripts/restart-app.sh --stable
```

This builds all products, installs `Banyan.app` to `/Applications`, and places
the companion CLI at `dist/bin/banyanctl`. For iterative development, use
`swift run Banyan` or `./scripts/dev-watch.sh`.

## Slack session browser

The Slack integration can browse existing sessions and read their available
context from App Home. Away mode follows selected sessions or projects and
delivers catch-up and subsequent notifications while the Mac is running. See
[Slack setup and history limits](docs/slack-native-control.md) for the private
channel, Keychain credentials, supported actions, and recovery instructions.

## Puck sessions

Start `puckd` after configuring an account with `puck auth login`. In the
macOS app, a puck session is a session like any other: it sits in its project
group in the **Sessions** list with a jump key, a status, and its provider's
icon and model, and it answers to the same shortcuts. **New Session** (⌘N)
starts another puck session on the same provider, model, and account; ⌘W
closes it; rename, suspend, and remove work as they do for terminal sessions.
Create one from a configured agent profile, or from the sidebar footer's
**Custom Session...** sheet with the **Puck** runtime, a provider, and an
optional account label and model.

Selecting a puck session shows its transcript, any pending approval or
question, and a message field. Banyan follows the daemon's event stream only
while the session is on screen. One `session.watch` connection keeps sidebar
state current across all sessions and declares Banyan's interactive capability.
Input renews the daemon's presence lease; app deactivation, screen lock, display
sleep, and system sleep report away immediately. Idle time expires the lease
in puckd, so leaving an attached window open does not keep Slack quiet forever.
While present, routed asks notify Banyan; while away, the daemon's notify peer
delivers them and catches up suppressed history. Both surfaces see the same
session and resolve the same pending call. Clicking a Banyan ask notification
opens `banyan://puck/SESSION_ID`.

Watch and transcript connections reconnect automatically with bounded backoff,
reconcile summaries, and replay durable events after a daemon restart. Empty
sessions emit no creation event, so Banyan also reconciles the catalog once a
minute at the desk or every five minutes in the background. Closing a puck
session in Banyan confirms removal from the sidebar; the session stays in
`puckd`, and **Reopen** brings it back. **Remove** also keeps a later listing
from adding it again. Terminal-only actions — Restart, Find, and
`banyanctl output`, `send`, and `answer` — do not apply to puck sessions; use
`banyanctl puck turn`, `decide`, and `answer` for those.

The TUI's `p` view and `banyanctl` use the same local daemon socket:

```sh
banyanctl puck new --provider codex --account work --model gpt-6-luna --cwd "$PWD" --prompt "Inspect this repository"
banyanctl puck list
banyanctl puck attach --id SESSION_ID
banyanctl puck decide --id SESSION_ID --call-id CALL_ID --decision approve
banyanctl puck plan --id SESSION_ID
banyanctl puck reject --id SESSION_ID --call-id CALL_ID --reason "Cannot handle this call"
```

`PUCK_HOME` selects a non-default puck data directory. Banyan's puck launch
surfaces support `codex`, `opencode-go`, `anthropic`, and `gemini`. The latter two
use separately billed API-key accounts and require an explicit model and account
label. Profiles without `puck_provider` and plain shells retain their terminal
backends.

## Codex automatic retries

Banyan automatically continues native and terminal Codex sessions after recognized
capacity, overload, temporary rate-limit, and connection failures. It keeps the
same conversation and model, and waits approximately 15, 30, 60, and 120 seconds
before giving up. The session banner shows the next retry and offers **Cancel
Retry**. Typing, interruption, closure, and disabling **Preferences → Codex →
Automatically retry transient Codex failures** cancel pending recovery.

Terminal recovery requires a verified live Codex process and a recognized error
immediately above an empty composer. Ambiguous layouts are left for manual
recovery. Quota, sign-in, context, approval, and policy errors are not retried.
See [the recovery policy](docs/codex-auto-retry.md) for details and limitations.

## Run the macOS app

```sh
swift run Banyan
```

For iterative UI work, use the dev watcher:

```sh
scripts/dev-watch.sh
```

It rebuilds and restarts only the Banyan client when Swift package files change. Backing `tmux -L banyan` sessions remain alive across restarts, so running agents and shells are not killed.

The app starts a local control server on `127.0.0.1:7842`.

Live terminal processes are kept by `tmux -L banyan` using session names prefixed with `banyan-`.

Session and workspace state are saved to SQLite. Data stays local to each
machine:

```text
macOS: ~/Library/Application Support/Banyan/state.sqlite
Linux:  $XDG_DATA_HOME/Banyan/state.sqlite or ~/.local/share/Banyan/state.sqlite
```

The local control server listens only on `127.0.0.1:7842`. Its token is stored
next to the database as `control-token`; `banyanctl` loads it automatically.

Run only one Banyan frontend at a time when using the default data directory:
the macOS app and TUI share port `7842`, the `banyan` tmux socket, and the same
SQLite state.

On first launch after upgrading, Banyan migrates legacy session metadata from `sessions.json` when the SQLite database has no sessions.

Persisted state currently includes session metadata, tmux session names, generated titles, sidebar order, selected session, sort mode, terminal theme, and terminal font settings.

## Session launch profiles

The project-group `+` menu reads optional launch profiles from
`~/.banyan/config.yml` when Banyan starts. Each profile has a stable `id`; the
last profile selected for each project group is remembered by that ID. This
makes it safe to rename a label or define several variants of the same agent.

```yaml
session_launches:
  - id: codex
    label: Codex
    provider: codex
    command: codex
  - id: codex-puck
    label: Codex (Puck)
    provider: codex
    command: codex
    puck_provider: codex
  - id: codex-fast
    label: Codex Fast
    provider: codex
    # Optional SF Symbol or local PNG/JPEG/ICNS image path.
    icon: ~/.banyan/icons/codex-fast.png
    command: codex --model gpt-6-luna
    # Explicit puck settings preserve the model/account selected by the profile.
    puck_provider: codex
    puck_model: gpt-6-luna
    puck_account: personal
  - id: claude-opus
    label: Claude Opus
    provider: claude
    command: claude --model opus
```

`id`, `label`, and `command` are required strings. `provider` is optional and
selects a known provider icon (`claude`, `codex`, `deepseek`, `gemini`, and the
other Banyan providers); unknown providers use a generic icon. `icon` is an
optional SF Symbol name (for example, `bolt.fill`) or local image path. Image
paths can be absolute, start with `~`, or use a `file://` URL, and override
provider branding. Commands are passed to the session shell unchanged, so
quote YAML values when needed.

The native Codex App Server client is a separate preview. Enable **Preferences →
Codex → Enable native Codex client (preview)**, then choose **Codex (Native)** in
the new-session sheet. Native sessions offer **Use Codex CLI** to continue their
exact thread in a terminal if startup or capabilities fail. The native toggle
can be disabled independently of CLI, remote-control TUI, and Puck runtimes.
See [runtime selection, compatibility, and fallback](docs/codex-app-server-client.md).

The built-in `Codex` profile opens a terminal session; `Codex (Puck)` opens a
puck daemon session. A configured profile uses puck only when it declares
`puck_provider` (`codex`, `opencode-go`, `anthropic`, or `gemini`); `puck_model` and
`puck_account` select the exact model and a label in puck's own account store.
Both fields are required for `anthropic` and `gemini` and optional for the other
providers. The shared agent registry accepts `puckProvider`, `puckModel`, and
`puckAccount` for the same purpose.
Configure puck credentials with `puck auth login`, then start `puckd` before
launching those profiles. Opaque commands such as `codex -p fast` remain tmux
sessions until given explicit puck settings, because Banyan cannot infer the
model or account that another CLI profile would choose. Other agent backends
continue using their configured commands until puck supports their credential
and API contracts.
Anthropic Console and Gemini AI Studio API-key accounts require explicit
`puck_model` and `puck_account`. These are separately billed API routes; the
existing Claude and Gemini subscription profiles stay on their configured
commands.

A puck session can be opened in the macOS app with `banyan://puck/SESSION_ID`.
For a Slack button, host [the static redirect page](docs/puck-session-redirect.html)
at an HTTPS origin and set puck's `PUCK_SESSION_URL_TEMPLATE` to
`https://your.example/puck-session-redirect.html?session={session}`. The page
validates the ID, opens the local app link, and shows a manual button if the
browser does not open Banyan automatically. No Banyan server or private host is
required for the redirect page.
The same session ID also works with `banyanctl session list`, which lists a
puck session once whether or not Banyan is running, and
`banyanctl puck attach --id SESSION_ID`.
The project picker, New Session shortcut, and command palette use a profile's
puck settings. `banyanctl agent run --profile PROFILE_ID` uses the same profile
when Banyan is running; `--agent codex` resolves the terminal `codex` profile,
while `--profile codex-puck` selects puck.
Puck launches accept the same `--id`, `--cwd`, `--prompt`, title, tone,
parent, and focus/background options as terminal launches.

When this file is absent or omits `session_launches:`, Banyan falls back to
the shared registry at `~/.agents/agents.yml` (entries with `tags: [banyan]`,
respecting `picker: false` and `banyanCommand`), so `workit sync` is no longer
required for the picker — you can omit the `session_launches` section
entirely. If neither source is available, Banyan uses the built-ins `zsh`,
Claude, Codex, and Codex (Puck). If the file cannot be read or is invalid
(including duplicate IDs or no profiles), Banyan starts with those built-ins
and shows the parsing diagnostic in Preferences. An old remembered profile ID
that is no longer configured falls back to the `zsh` profile, or the first profile when
no `zsh` profile is configured.

## Custom palette commands

The ⌘P palette supports user-defined commands from `~/.banyan/palette.yml`
(preferred) or the `palette_commands:` section of `~/.banyan/config.yml`.
Prefer `palette.yml`: `config.yml` is rewritten by `workit sync`, which would
drop a hand-added section. When both define the same `id`, the `palette.yml`
entry wins. Commands are personal workflows (for example `~/bin/workit` or
`~/bin/verify-linear`), so they live in config — never as builtins.

```yaml
palette_commands:
  - id: work
    title: "Work on {{target}}"
    command: "~/bin/workit {{target}} {{agentFlag}}"
    run: session      # spawn a visible Banyan session
    when: issue       # promote when the query has a Linear/GitHub target
    parent: root      # root-level session (default); `current` nests under the selection
  - id: verify
    title: "Verify {{target}}"
    command: "~/bin/verify-linear {{target}}"
    run: background   # run detached like banyan-worktree, then refresh
    when: linear
```

`id`, `title`, and `command` are required. `run` is `session` (default) or
`background`. `when` is `always` (default), `issue`, `linear`, or `github`.
`parent` is `root` (default) or `current`.
`{{target}}` (aliases `{{id}}`, `{{issue}}`) expands to the Linear ID or
GitHub issue URL detected in the palette query, falling back to the selected
Linear issue / session for static rows; `{{query}}` expands to the raw query.
`{{agentFlag}}` expands to `--agent <id>` when an agent is picked in the
palette's agent picker (Tab cycles it) and to nothing on Auto, so a helper
keeps its own weighted default rather than receiving a dangling flag;
`{{agent}}` expands to the bare id. Both are opt-in — add them only for
commands whose helper accepts `--agent` (for example `workit` and
`review-linear`), and note the helper may restrict the name to its own tag
pool. Typing `ENG-123` promotes matching commands above the built-in
quick-open rows. Parse errors clear custom commands and show a diagnostic in
Preferences. There is no JSON config for this — YAML only.

`parent` defaults to `root` because the Banyan app inherits
`BANYAN_SESSION_ID` (and `TMUX`) from whatever pane launched it. Handing that
environment to a helper like `workit` unchanged makes the new session a child
of that pane's session — a stale, unrelated id that may since have closed, in
which case the spawn is rejected outright. `root` clears that inherited
identity so the session lands at the top level; `current` instead parents it to
the session selected at launch time. The built-in quick-open
"Start Session for `<ID>`" row always lands top-level.

## Dev / Stable Builds

Two channels, never running at the same time (they share control port 7842 and `state.sqlite`):

- **dev** — `scripts/dev-watch.sh` (debug build, auto-rebuild on change) or `dist/Banyan.app` (packaged candidate).
- **stable** — `/Applications/Banyan.app`. Promoted explicitly by running `scripts/package-app.sh`, which stamps the git SHA into `CFBundleVersion` and archives the outgoing install to `dist/Banyan-previous.app`.

Switching is one command; it gracefully stops whichever instance is running (packaged or dev-watch debug binary), waits for the port, and launches the requested channel. Sessions survive every switch because tmux owns them:

```sh
scripts/restart-app.sh                    # relaunch the packaged candidate
scripts/restart-app.sh --stable           # switch to /Applications/Banyan.app
scripts/restart-app.sh --stable --force   # dev build is hung: SIGKILL it first
scripts/restart-app.sh --previous         # roll back to the pre-promotion stable
scripts/restart-app.sh --here             # use this checkout, not the main one
```

### Which checkout gets built and launched

`package-app.sh` and `restart-app.sh` act on the **main checkout** by default,
even when invoked from a linked worktree — after merging, the intent is normally
"run what is on main". Both print the checkout they resolved to. Pass `--here` to
act on the worktree the script lives in (testing an unmerged change), or set
`BANYAN_ROOT` to pin one explicitly.

Because the two channels share port 7842 and `state.sqlite`, `restart-app.sh`
also refuses to launch while another Banyan still owns the port, and names the
process that holds it. Quit that instance, or pass `--force`.

### Reboot recovery

Cmd+Q leaves the dedicated tmux server and running sessions alive. A machine
restart stops that tmux server and its child processes, while Banyan's metadata
remains in `state.sqlite`. On the next launch, active sessions whose tmux
backing disappeared resume automatically in the background when their folder is
already accessible. Codex, Claude, and opencode-backed sessions (opencode,
deepseek, hunyuan, muse-spark, qwen) use their saved exact provider session ID,
so recovery creates a fresh tmux session with `codex resume`, `claude --resume`,
or the equivalent instead of replaying the original prompt. Sessions without a
saved ID, parked sessions, terminal sessions, finished rows, and folders that
need a macOS permission grant remain available through the selected-session
**Recover** button, row context menu, or sidebar **Recover All** action.

Check which build an install is: `defaults read /Applications/Banyan.app/Contents/Info CFBundleVersion`.

Older stable builds can read a newer `state.sqlite` because migrations are additive only (`CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ADD COLUMN`) — keep them that way.

## iTerm2 Rescue

If the Banyan app is hung or broken, all sessions are still reachable — they are plain tmux sessions. The rescue script lays them out in iTerm2, one tab per project and one pane per session:

```sh
scripts/iterm-rescue.sh              # attach everything
scripts/iterm-rescue.sh --dry-run    # print the tab/pane plan
scripts/iterm-rescue.sh -p myproject # only one project
scripts/iterm-rescue.sh -d           # kick other clients (including a wedged Banyan)
```

It talks to tmux and `state.sqlite` directly and never depends on the Banyan app or control server. Terminal content stays in sync with Banyan automatically because both are tmux clients of the same sessions; closing panes only detaches them.

## Performance Telemetry

Banyan collects local, CWV-like performance events for app-specific workflows such as switching sessions, attaching terminals, refreshing tmux clients, and resolving selected-session context. The data is stored locally in:

```text
~/Library/Application Support/Banyan/state.sqlite
```

Use the CLI report before investigating performance issues:

```sh
dist/bin/banyanctl perf report --since 7d
dist/bin/banyanctl perf report --since 7d --json
dist/bin/banyanctl perf captures --since 12h --json
```

Important metrics include `session_switch.total`, `session_switch.to_terminal_ready`, `session_switch.to_first_output`, `terminal.ready_wait`, `terminal.start_client`, `terminal.reattach_client`, `tmux.refresh_clients`, and `selected_context.resolve`.

For Energy Impact attribution, including the tmux and agent-process limitations,
see [docs/energy-impact.md](docs/energy-impact.md).

To turn the collected report into a targeted agent task:

```sh
dist/bin/banyanctl perf prompt --since 7d
dist/bin/banyanctl perf fix --since 7d --agent codex --cwd "$PWD"
```

`perf fix` does not silently rewrite the running app. It creates a Banyan-native coding-agent session with the local telemetry report as evidence, so fixes still go through normal code review and test flow.

## Session Retention

Closed sessions used to stay in `state.sqlite` forever, and that history is not
free: the restore path resolves repository context once per *distinct* working
directory, on the main thread, before the first window appears. A database
carrying years of dead worktrees therefore makes a cold start scale with
directories nobody will reopen rather than with the sessions you actually have.

Preferences → Sessions sets how long a closed session is kept. The default is 30
days; pick **Never** to keep everything. Banyan applies the window once at
launch, before it builds any session from the database, and never from the save
path the supervisor runs on every tick.

A row is removed only when all of these hold, so a prune can never cut a live
session or orphan one:

- its status is `closed`
- it has not been updated inside the retention window
- it is not the selected session
- it is not an ancestor of a session that stays

"Clean Up Now" in the same section applies the window immediately and reports
what it removed. From a script:

```sh
dist/bin/banyanctl prune --dry-run               # how many rows would go
dist/bin/banyanctl prune                         # apply the configured window
dist/bin/banyanctl prune --older-than 90         # apply 90 days just this once
```

`prune` drives the running app rather than the database file, because the app
rewrites the whole `sessions` table on its next supervisor tick — rows deleted
behind its back would simply come back. `--older-than` does not change the
stored setting.

## Package

```sh
scripts/package-app.sh
scripts/restart-app.sh --stable
```

The packaging script builds all products, creates `dist/Banyan.app`, installs a
copy to `/Applications/Banyan.app`, and writes the companion CLI to
`dist/bin/banyanctl`. It uses a Developer ID identity when one is available and
falls back to an ad-hoc signature for local development. There is currently no
separate installer or notarized release channel.

## Concurrent agent slots

New managed agent work shares a configurable admission budget (four slots by
default). Queued sessions remain visible, with Run Next and Cancel actions.
Idle, parked, and frozen CLI agents hold their slots until something waits for
capacity: queued work then takes the least recently used idle reservation, and
that agent re-adopts one as soon as it is observed working again. Nothing is
signalled. Native active turns are counted individually even when they share
one server. Existing running work is preserved when restoring or lowering the
cap. Plain shells remain available.
See [Concurrent agent admission](docs/agent-admission.md) for counting rules,
CLI queue controls, uncertainty handling, and private runtime verification.

## Control From Scripts

Keep Banyan open, then drive it from another shell:

```sh
swift run banyanctl spawn \
  --id TASK-123 \
  --title "TASK-123" \
  --cwd ~/dev/my-project \
  --cmd "codex"

swift run banyanctl spawn \
  --parent TASK-123 \
  --id TASK-123-sub-1 \
  --title "TASK-123 subtask" \
  --cwd ~/dev/my-project \
  --cmd "codex"

swift run banyanctl session new \
  --title "Scratch shell" \
  --cwd "$PWD"

swift run banyanctl agent run \
  --agent codex \
  --cwd "$PWD" \
  "implement keyboard shortcuts"

swift run banyanctl agent run \
  --agent claude \
  --prompt-file /tmp/prompt.txt

swift run banyanctl mark --id TASK-123 --status need-input --tone yellow
swift run banyanctl mark --id TASK-123 --status review --tone purple --title "TASK-123 review"
swift run banyanctl suspend --id TASK-123
swift run banyanctl resume --id TASK-123
swift run banyanctl reparent --id TASK-123-sub-1 --parent TASK-123
swift run banyanctl reparent --id TASK-123-sub-1 --no-parent
swift run banyanctl close --id TASK-123
swift run banyanctl respawn --id TASK-123
swift run banyanctl remove --id TASK-123
swift run banyanctl list
swift run banyanctl session list --id TASK-123
swift run banyanctl session list --all --query "widget"
swift run banyanctl prune --dry-run
swift run banyanctl suggest --title "TASK-123 is stale" --target TASK-123 --command "workit TASK-123"
```

`session new` is the preferred native terminal creation command; `spawn` remains as the low-level API-compatible alias. `agent run` builds an agent command, creates a Banyan session through the same control server, and lets Banyan detect the provider icon and generated title from the command. `--parent` groups a spawned session under another active session in the sidebar. Nesting can be arbitrarily deep. A spawn issued from inside a Banyan session nests under it by default: `banyanctl` takes `--parent` from `$BANYAN_PARENT_SESSION_ID`, then the live enclosing `banyan-<id>` tmux session, then `$BANYAN_SESSION_ID` (every tmux session Banyan creates carries its own ID) — so `workit ENG-123` run from a session pane lands as its child with no extra flags, even if a long-lived parent process inherited a stale ID. Pass `--parent ID` for a different parent, or `--no-parent` for a top-level session. `suspend` parks a session: Banyan drops it from the supervisor tick, branch/context refresh, and terminal rendering, while its tmux session and any agent inside keep running untouched — so the app's idle cost tracks the sessions you are actually watching rather than every session you have open. `resume` puts it back, keeping the status it had when it was parked. Neither one signals or terminates the agent. `close` detaches and hides the Banyan view while leaving the tmux session alive. If a closed session has child sessions, those children are detached to the closed session's parent level. `respawn` reattaches to an existing tmux session or recreates it from the saved command if it no longer exists. `remove` is destructive and kills the backing tmux session. `prune` drops closed sessions that aged out of the retention window — see [Session Retention](#session-retention).

To move an existing session, use `reparent --id CHILD --parent PARENT`, or
`reparent --id CHILD --no-parent` to move it to the root. In the sidebar,
right-click an active session to use **Move Up**, **Move Down**, **Indent Under
Previous Sibling**, **Move Out One Level**, **Move to Top Level**, or **Move
to…**. The commands preserve the session's subtree, and **Move to…** lists the
active hierarchy, including collapsed and hidden targets in the same project
group.

You can also drag a session row. Drop on the top or bottom edge to place its
subtree before or after the target at the target's level; drop on the center to
make it the target's last child. A collapsed target expands to reveal the moved
session. Reordering switches the sidebar to manual sort.

Within the same project group, moves keep the session's ID, process, metadata,
and children. Self-parenting, cycles, missing or closed targets, and moves
across project groups are rejected before any state is changed. The CLI
requires an explicit target and does not inherit a parent from the environment.

HTTP clients use authenticated `POST /reparent` with a JSON body:

```json
{"id":"child-id","parent":"new-parent-id"}
```

An empty, null or absent `parent` moves the source to the root. Success returns
the updated `session` in the usual control response envelope; invalid moves
return HTTP 400 with an error message and leave persisted state unchanged.

Session lists return detailed **active sessions** by default: every row except
closed history, including completed, failed, parked and suspended sessions that
remain open. `--all` includes closed history. `--id ID` returns one exact session
even if it is closed. `--query TEXT` searches IDs, titles, issue URLs and working
directories without regard to case; combine it with `--all` to search history.
These filters apply to both `list` and the unified `session list`. HTTP clients
use `GET /list?all=true&query=widget` or `GET /list?id=TASK-123`; filtering happens
before detail serialization. Consumers that used closed rows from the previous
unfiltered list must now request `--all` explicitly.

### Suggesting Work Instead Of Starting It

Every command above acts the moment it is called. `suggest` is the one that
waits: it pushes a proposal into the app's sidebar, and the command runs only if
a human presses **Run**.

```sh
swift run banyanctl suggest \
  --title "TASK-123 has been in review for 6 days" \
  --detail "No reviewer assigned; SLA breaches tomorrow" \
  --target TASK-123 \
  --key "stale-review:TASK-123" \
  --command "workit TASK-123"
```

Banyan owns only the interaction — render it, capture the decision, run the
command on approval. The *policy* behind a nudge stays outside: which issue has
gone stale, whose review is overdue, whose due date is about to breach. `--target`
and `--command` are opaque to the app, so a picker can suggest an issue today and
a pull request tomorrow without Banyan learning either. Approving runs the command
through the same path a custom palette command takes, so `{{target}}`,
`{{agent}}` and `{{agentFlag}}` expand the same way and the result appears in the
same sidebar banner, log file included.

| Flag | Meaning |
| --- | --- |
| `--title` | Required. The headline the human reads. |
| `--command` | Required. The shell command to run on approval, and at no other time. |
| `--detail` | Why this is worth attention. |
| `--target` | Opaque subject (issue id, URL), expanded into the command's `{{target}}`. |
| `--key` | Idempotency key. Defaults to `--target`, then to the command. |
| `--cwd` | Where to run. Defaults to the selected session's directory. |
| `--run` | `session` (default) or `background`, like a palette command's `run:`. |
| `--ttl` | Seconds the suggestion stays live. Default 3600, min 60, max 86400. |

One suggestion is shown at a time, and a scheduled picker must not raise the same
nudge on every tick, so the TTL governs both: while a suggestion is live it holds
the single pending slot, and its `--key` is refused. Answering it frees the slot
immediately but keeps the key suppressed for the rest of the TTL — acting on a
nudge should not invite the next tick to repeat it. Key on `<kind>:<issue>` when
the same issue can earn different kinds of nudge; keying on the issue alone
collapses them into one.

Exit codes make this usable from `cron` or `launchd` without parsing output:

```sh
#!/bin/sh
# Pick one issue worth attention and offer it. Policy lives here, not in the app.
issue=$(my-issue-picker) || exit 0

banyanctl suggest \
  --title "$issue needs a reviewer" \
  --target "$issue" \
  --key "stale-review:$issue" \
  --command "workit $issue"

case $? in
  0)  ;;   # delivered
  75) ;;   # refused for now: already pending, or this key is still suppressed
  69) ;;   # Banyan is not running; skip this tick
  *)  exit 1 ;;
esac
```

75 is `EX_TEMPFAIL` — the request was fine, the slot was simply taken. 69 is the
same "app is not running" code every other `banyanctl` command returns, which is
the fail-closed skip a scheduled picker wants. Nothing is queued while the app is
closed; the next tick offers again.

The control API uses a versioned JSON schema (`apiVersion: "v1"`) and a local shared token stored at:

```text
~/Library/Application Support/Banyan/control-token
```

`banyanctl` sends this token automatically with `X-Banyan-Token`.

Supported statuses:

```text
running
need-input
review
completed
failed
closed
```

Supported tones:

```text
neutral
blue
green
yellow
red
purple
```

## Terminal Rendering

Banyan embeds [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT
licensed, vendored under `Packages/SwiftTerm` with local rendering and
child-process-lifecycle patches), so
terminal applications can use ANSI, 256-color, and truecolor escape sequences
for syntax highlighting and colorized output. Banyan exposes app theme and
terminal font controls in Preferences.

Banyan advertises `TERM=tmux-256color` in panes and `COLORTERM=truecolor`
with `CLICOLOR=1`. It leaves color detection to each tool, so piped output
can remain suitable for parsing, and preserves an inherited `NO_COLOR`.
It does not add `CLICOLOR_FORCE` or `FORCE_COLOR`.

Upgrading the app does not clear the environment of an already-running tmux
server or its panes. A server started by an older version can retain the old
forcing variables; newly created panes inherit that server's environment.
After those variables are cleared from the server, existing panes and their
descendants still keep their old environment until restarted. Restarting only
the Banyan client does not refresh it.

The embedded terminal supports normal desktop text selection and clipboard shortcuts. Drag to select visible terminal text, use `Cmd+C` to copy the selection, and use `Cmd+V` to paste into the active tmux-backed session.

Theme options:

- System
- Dark
- Light

The selected theme applies to both the SwiftUI chrome, such as the sidebar, and the embedded terminal.

## Agent State Detection

Banyan watches terminal output for common agent states and can mark sessions as `need-input`, `review`, `failed`, or `completed`. It sends macOS notifications for attention states.

### Main-session coordination

An external coordinator such as `workit group` can keep one existing conversation
in charge of a bounded set of issue workers. The default Sessions tree stays in
place; children and completed verifier helpers are nested under their owner.

`banyanctl session current` resolves the caller from its actual tmux pane or exact
native Codex thread binding. Spawn-parent overrides and sidebar selection do not
change that identity. The authenticated `banyanctl coordination` protocol supports
binding an owner, observing child input, delivering a numbered notification,
resolving uncertain receipts and retiring a scoped verified child into history.
The owning coordinator decides when evidence is accepted; Banyan checks original
parent/job/revision, direct user input and live session state before closing.

Coordinator bindings and receipts live separately from issue workflow badges in
the private `Banyan/coordination/` journal. Switching away from a native coordinator
keeps its remote observation available. Busy turns, drafts, holds and human
prompts prevent automatic input. Ambiguous delivery is never replayed without
inspection. Selected, busy, changed or uncertain children remain open; transcripts
and worktrees are retained. This transport adds no scheduler or default sidebar.
Use `banyanctl coordination --help` for the versioned control interface.

If coordination input could not be journaled, repair the coordination storage
and run `banyanctl coordination inspect-recovery --id CHILD --parent OWNER
--group-id GROUP`. Inspect the original conversation and the returned interventions
for potentially lost input. If the response says recovery is possible, run
`banyanctl coordination recover --id CHILD --parent OWNER --group-id GROUP
--inspection-id ID --detail 'What was inspected and how missing input was handled'`.
The inspection ID is valid only while the failure, relationship and journals remain
unchanged. The acknowledgment is recorded as an intervention; no input is replayed.
Workflow journal errors require separate repair, and workflow holds and delivery
receipts remain in force. Observe the child again before acknowledging its latest
intervention for retirement.

### Managed issue workflows

The native close confirmation can **Pause and Close** unfinished Workit-owned
sessions after Workit acknowledges the exact job/session and Banyan confirms
its matching paused projection. The issue stays unfinished. See
[configuration, CLI requirements and recovery](docs/pause-and-close.md).

An external supervisor such as [workit](https://github.com/banyudu/workit/issues/6)
can attach an independent workflow badge: Working, Auto-waiting, Needs you,
Verified, Paused or Cancelled. Process completion does not establish issue
verification. Banyan owns session control/presentation; the supervisor owns
scheduling, acceptance evidence and tracker closeout. There is no workflow
scheduler inside Banyan.

```bash
banyanctl workflow set --id TASK-123 --owner workit --job-id job-a --revision 1 --state waiting --detail "Waiting for deployment"
banyanctl workflow wake --id TASK-123 --job-id job-a --revision 1 --wake-id wake-a --text "Continue acceptance on the observed deployment."
banyanctl workflow close-verified
```

`banyanctl session list` advertises `workflowProtocol: 1` and returns each managed
session's workflow metadata separately from its process status. Owner/job
identity is immutable; revisions must increase for changed state/detail.
Same-revision identical updates are idempotent.

Wakes use the authenticated control API. They inspect the current pane and agent
process, reject busy/parked/frozen/approval states and drafts, and send literal
text only to a recognized empty conversation input. Used turns may be labeled
`need-input`; that label alone is insufficient. Unknown input shapes remain
held. Native Codex sessions use their existing turn API. Missing/dead terminal
backends require the exact original conversation in the provider's disk store
at the same cwd; they never replay the original task or choose the newest thread.

The private `Banyan/workflows/` journal records intent before delivery. A
delivered wake ID is acknowledged without another turn; pending/uncertain
receipts require inspection. A receipt acknowledges delivery or queued native
resume, not successful execution or acceptance. After inspecting the original
conversation and external effects, a supervisor can explicitly reconcile:

```bash
banyanctl workflow resolve --id TASK-123 --job-id job-a --revision 1 --wake-id wake-a --outcome delivered --detail "Observed the original continuation"
```

`not-delivered` clears the receipt only when inspection establishes no delivery.
The workit CLI also preserves a recovery record and requires explicit resume.
Journal failures block continuation. Old/unmanaged saved sessions need no
migration.

A refusal proven to occur before any prompt bytes were sent records a
`not-delivered` receipt, allowing the same wake ID to retry automatically.

Unfinished managed sessions are protected from ordinary close, which otherwise
can terminate their agent. Verify them or explicitly pause/cancel their workflow
first. The sidebar menu and CLI offer **Close verified sessions**, selecting
only verified sessions without active work/human input. Explicit removal remains
destructive and requires supervisor recovery. Pausing a workflow stops future
wakeups; interrupt its active turn separately when needed.

Coding-agent sessions launched through `claude`, `codex`, `deepseek`, `gemini`, `glm`/`zai`, `mimo`, `minimax`, or `opencode` get a compact provider badge in the sidebar. If a session has a manual title, Banyan keeps it. Otherwise it derives a title from the agent-reported or agent-generated thread name, the prompt passed to the agent command, the first prompt submitted interactively (read back from the agent's own transcript when the agent never names the thread), or a compact provider/session fallback.

New Codex, Claude Code, and OpenCode terminal sessions launched by Banyan also
receive a session-scoped `rename_session` tool. Native Codex sessions receive it
on connect. The agent is instructed to choose a concrete task title and update
it when significant findings or the outcome become clear — for example,
`what happened on this <url>` can become `Checkout timeout: exhausted DB pool`.
These titles persist across app restarts and outrank the opening prompt and
terminal title. Manual renames always win. Clearing a conversation clears its
automatic title. No separate title-generation model, API key, or polling is
needed; the active agent chooses the wording and timing.

The integration adds MCP configuration only to that agent invocation; it does
not edit global agent settings. Already-running terminal agents get the tool
when next launched or resumed through Banyan. Agents started manually inside a
shell, custom wrapper commands, remote Codex TUIs, and Puck sessions keep their
existing naming behavior. Set `BANYAN_AUTO_RENAME=0` in the agent launch
environment to disable injection. An agent or script can also update its own
automatic title with `banyanctl session title --title "Specific finding"`
(or supply `--id ID` explicitly); this never pins the title or overrides a
manual rename. `banyanctl mark --title` remains a manual, pinned rename.

For local model or cheap hosted title generation, set `BANYAN_TITLE_COMMAND` before launching Banyan. The command receives a JSON object on stdin and should print one short title on the first stdout line:

```sh
BANYAN_TITLE_COMMAND=/path/to/title-script swift run Banyan
```

Global detector rules can be overridden with:

```text
~/Library/Application Support/Banyan/detectors.json
```

Example:

```json
[
  {
    "status": "need-input",
    "tone": "yellow",
    "patterns": ["waiting for approval", "permission required"]
  }
]
```

## Worktree Handoff (Optional)

Handoff is an optional workflow for passing an idle agent session's worktree to
an external dispatch process (for example, a script that ships the branch and
cleans up). It stays hidden unless both halves are in place: **Show the worktree
handoff action** is enabled in Preferences (off by default, so the workflow is
opt-in) and a handoff executable is installed. Banyan looks for `~/bin/handoff`,
or the path in `BANYAN_HANDOFF_COMMAND` if set. When either is missing, the
handoff button and the ⇧⌥⌘H shortcut stay hidden.

When configured, eligible sessions (idle coding agents in a git worktree on a
non-default branch) show a handoff button in the sidebar. Dispatch closes the
session and runs `<handoff-command> dispatch` in the session's working
directory; if the command fails, the session is restored.

## Current Scope

Banyan is currently distributed from source and via GitHub Releases. The
package script creates a locally installable app, but distribution signing and
notarization are not yet part of the release flow.

## License

Banyan is released under the [MIT License](LICENSE). The vendored
`Packages/SwiftTerm` retains its own MIT license and copyright.

### Durable work overview

**Sessions remains the main working surface.** Existing parent rows summarize
their child sessions, including nested, collapsed and background work. Idle
conversations are counted as idle, not as completed issues. Managed session rows
show specific saved work status such as Tool error, Waiting for CI, or Verified.
Click a status or parent summary to open **Work details** without replacing the
conversation. The panel shows the original stop reason, next step, saved
acceptance evidence and links; select a child to return to its conversation.
**Copy inspection request** copies a recovery question to paste into that
conversation. It does not send a prompt or resume a held job.

Details refresh on app activation, explicit refresh and coalesced workflow
updates. A single bounded read serves the whole tree. Old or mismatched job
bindings fall back to the session's own workflow status. Tool failures and
uncertain delivery remain blocked; displaying a reason never clears a hold.

Choose **Work** in the sidebar switcher to see managed jobs across conversations.
This optional overview includes jobs whose original conversation is unavailable.
Jobs are grouped by working, waiting, attention, paused, verified, and cancelled.
Each row shows the saved checkpoint, proven acceptance count, next action, and
available issue, PR, evidence, and conversation links. The progress timestamp
changes with meaningful checkpoints, not each heartbeat. Older jobs show an
unknown progress time until a new checkpoint is recorded.

The view uses the same host-owned `~/.banyan/workit.json` configuration as Pause
and Close, with an absolute `invocation` argv array and `stateDirectory`. It needs
a Workit version supporting `job overview --format json` (schema version 1).
It refreshes on opening, app activation, and the refresh button. Errors retain
previous results with a stale-results notice; no tracker or workflow mutation
occurs when opening the view. Missing or closed conversations do not remove jobs.

For an active managed conversation, the close dialog offers **Keep Working in
Background**. Its compact row remains in Sessions with a background indicator,
and its children collapse while work continues. The selected sidebar does not
change. Future children inherit background membership. Selecting the conversation
brings it back. Backgrounding never pauses, suspends,
closes, terminates, or verifies the job; **Pause and Close** retains its existing
meaning. Active managed native threads retain their observation subscription so
Workit can continue them while their conversations are hidden or unselected.
